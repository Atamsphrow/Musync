import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musync/core/app_info.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

/// LRCLIB (https://lrclib.net) — free, no API key, built for FOSS players.
///
/// Two endpoints are used together: `/get` answers with the single best match
/// when the duration is known, `/search` casts a wider net for when the file's
/// tags are wrong. Their results overlap, so they are merged by track id.
class LrclibSource extends LyricsSource {
  /// The public instance. LRCLIB is self-hostable and its API is documented, so
  /// pointing this at another deployment is all a "custom source" needs to be
  /// (plan P5) — see [LrclibSource.custom].
  static const String defaultBaseUrl = 'https://lrclib.net/api';

  /// LRCLIB asks clients to identify themselves so it can contact maintainers
  /// about misbehaving apps rather than just blocking them.
  ///
  /// Derived from [AppInfo] rather than written out: this string announced
  /// `1.0.0` long after the app had moved on, and a version LRCLIB cannot
  /// trust is a version it cannot use — it also skews the traffic split it
  /// publishes. `app_info_test.dart` already fails the build when
  /// [AppInfo.version] and `pubspec.yaml` disagree, so sourcing it here means
  /// the header can no longer drift on its own.
  static const String _userAgent =
      '${AppInfo.name}/${AppInfo.version} (https://github.com/atamsphrow/musync)';

  static const Duration _timeout = Duration(seconds: 12);

  /// `/get` matches on duration within a couple of seconds; anything past this
  /// is a different recording, however well the title matches.
  static const int _durationToleranceMs = 3000;

  final http.Client _client;

  /// Where to send requests. Always an LRCLIB-shaped API.
  final String baseUrl;

  /// A final field satisfies the abstract getter on [LyricsSource], which keeps
  /// the name settable per instance without a second accessor.
  @override
  final String name;

  LrclibSource({http.Client? client})
    : _client = client ?? http.Client(),
      baseUrl = defaultBaseUrl,
      name = 'LRCLIB';

  /// Another LRCLIB deployment, named by the user.
  ///
  /// Deliberately not "any lyrics API": a source has to return something this
  /// code can read, and describing an arbitrary JSON shape through a settings
  /// form would be both a large feature and an unusable one. LRCLIB is
  /// self-hostable and mirrored, so pointing at a different instance is the
  /// version of "custom source" that actually works — and anything genuinely
  /// different is a `LyricsSource` subclass, which is a ten-line file.
  LrclibSource.custom({
    required this.name,
    required this.baseUrl,
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
  }) async {
    // Keyed by LRCLIB track id so the same recording found by both endpoints
    // appears once, keeping whichever hit scored higher.
    final byId = <int, LyricsSearchResult>{};
    final unidentified = <LyricsSearchResult>[];

    void collect(Map<String, dynamic> json, double confidence) {
      final result = _toResult(json, confidence);
      if (result == null) return;

      final id = json['id'];
      if (id is! int) {
        unidentified.add(result);
        return;
      }
      final existing = byId[id];
      if (existing == null || confidence > existing.confidence) {
        byId[id] = result;
      }
    }

    // 1. Exact lookup. Only possible with a duration, and 404 simply means
    //    LRCLIB has nothing for this exact recording — not an error.
    //
    //    A failure here does not end the search. The two endpoints are used
    //    together on purpose, and letting this one throw meant a single slow
    //    exact lookup failed the source outright — even though the broad search
    //    below would have answered. The reason is kept in case *both* fail.
    LyricsSourceException? exactFailure;
    if (durationMs != null && durationMs > 0) {
      try {
        final exact = await _getJson(
          Uri.parse('$baseUrl/get').replace(
            queryParameters: {
              'artist_name': artist,
              'track_name': title,
              if (album != null && album.isNotEmpty) 'album_name': album,
              'duration': (durationMs ~/ 1000).toString(),
            },
          ),
        );
        if (exact is Map<String, dynamic>) collect(exact, 1.0);
      } on LyricsSourceException catch (e) {
        exactFailure = e;
      }
    }

    // 2. Broad search, to cover files whose tags don't line up with LRCLIB's.
    final Object? found;
    try {
      found = await _getJson(
        Uri.parse('$baseUrl/search').replace(
          queryParameters: {'artist_name': artist, 'track_name': title},
        ),
      );
    } on LyricsSourceException catch (e) {
      // Both endpoints failed, so the source really is unusable. The exact
      // lookup's reason comes first when there is one: it was the earlier
      // failure, and the two are almost always the same cause anyway.
      throw exactFailure ?? e;
    }

    if (found is List) {
      for (final item in found) {
        if (item is! Map<String, dynamic>) continue;
        collect(item, _score(item, title, artist, album, durationMs));
      }
    }

    final results = [...byId.values, ...unidentified]
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return results;
  }

  /// Decodes one endpoint's body, or throws [LyricsSourceException].
  ///
  /// 404 comes back as null: for `/get` it is the documented "no match", which
  /// is an outcome rather than a failure.
  Future<Object?> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: const {'User-Agent': _userAgent})
          .timeout(_timeout);
    } on TimeoutException catch (e) {
      throw LyricsSourceException(name, 'LRCLIB ne répond pas.', e);
    } on SocketException catch (e) {
      throw LyricsSourceException(name, 'Pas de connexion internet.', e);
    } on http.ClientException catch (e) {
      throw LyricsSourceException(name, 'Connexion à LRCLIB impossible.', e);
    }

    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw LyricsSourceException(
        name,
        'LRCLIB a renvoyé une erreur (${response.statusCode}).',
      );
    }

    try {
      // utf8.decode over response.body: http falls back to latin-1 when the
      // server omits the charset, which mangles every accent.
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (e) {
      throw LyricsSourceException(name, 'Réponse illisible de LRCLIB.', e);
    }
  }

  /// Ranks a `/search` hit. Exact title and artist carry most of the weight;
  /// the duration breaks ties between covers, live versions and remasters.
  double _score(
    Map<String, dynamic> item,
    String title,
    String artist,
    String? album,
    int? durationMs,
  ) {
    var score = 0.3;

    if (_looseEquals(item['trackName'], title)) score += 0.3;
    if (_looseEquals(item['artistName'], artist)) score += 0.2;
    if (album != null && _looseEquals(item['albumName'], album)) score += 0.05;

    final itemDuration = item['duration'];
    if (durationMs != null && durationMs > 0 && itemDuration is num) {
      final deltaMs = (itemDuration * 1000 - durationMs).abs();
      if (deltaMs <= _durationToleranceMs) score += 0.15;
    }

    // A synced hit outranks a plain one — it is the whole point of the app.
    final synced = item['syncedLyrics'];
    if (synced is String && synced.trim().isNotEmpty) score += 0.05;

    return score.clamp(0.0, 0.99);
  }

  static bool _looseEquals(Object? a, String b) =>
      a is String && a.trim().toLowerCase() == b.trim().toLowerCase();

  /// Builds a result, or null when the entry carries no usable lyrics —
  /// LRCLIB returns instrumental tracks with both fields empty.
  LyricsSearchResult? _toResult(Map<String, dynamic> json, double confidence) {
    SyncedLyrics? synced;
    final rawSynced = json['syncedLyrics'];
    if (rawSynced is String && rawSynced.trim().isNotEmpty) {
      final parsed = LrcParser.parse(rawSynced);
      if (parsed.isNotEmpty) synced = parsed;
    }

    UnsyncedLyrics? unsynced;
    final rawPlain = json['plainLyrics'];
    if (rawPlain is String && rawPlain.trim().isNotEmpty) {
      unsynced = UnsyncedLyrics(rawPlain);
    }

    if (synced == null && unsynced == null) return null;

    return LyricsSearchResult(
      source: name,
      title: json['trackName'] as String? ?? 'Titre inconnu',
      artist: json['artistName'] as String? ?? 'Artiste inconnu',
      album: json['albumName'] as String?,
      syncedLyrics: synced,
      unsyncedLyrics: unsynced,
      confidence: confidence,
    );
  }
}
