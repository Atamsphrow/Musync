import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_confidence.dart';
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
  static const String _userAgent =
      'Musync/1.0.0 (https://github.com/atamsphrow/musync)';

  static const Duration _timeout = Duration(seconds: 12);

  /// Pause before the single retry on a transient failure. One dropped request
  /// on a mobile network is routine; waiting a beat lets it go through.
  static const Duration _retryDelay = Duration(seconds: 1);

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
    FilenameGuess? filenameGuess,
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

    // The two endpoints are independent, so they run in parallel: running
    // them one after the other doubled the worst case (two timeouts plus a
    // retry each, ~50 s) for no reason. The exact lookup's failure is kept
    // for the error message when both fail.
    //
    // 404 on `/get` simply means LRCLIB has nothing for this exact recording
    // — an outcome, not an error — and a failure there does not end the
    // search: the broad search below may still answer.
    final exactFuture = (durationMs != null && durationMs > 0)
        ? _getJson(
            Uri.parse('$baseUrl/get').replace(
              queryParameters: {
                'artist_name': artist,
                'track_name': title,
                if (album != null && album.isNotEmpty) 'album_name': album,
                'duration': (durationMs ~/ 1000).toString(),
              },
            ),
          ).then<Object?>((v) => v, onError: (Object e) => e)
        : Future<Object?>.value(null);
    final broadFuture = _getJson(
      Uri.parse('$baseUrl/search').replace(
        queryParameters: {'artist_name': artist, 'track_name': title},
      ),
    ).then<Object?>((v) => v, onError: (Object e) => e);

    final settled = await Future.wait([exactFuture, broadFuture]);
    final exact = settled[0];
    final found = settled[1];

    LyricsSourceException? exactFailure;
    if (exact is LyricsSourceException) {
      exactFailure = exact;
    } else if (exact is Map<String, dynamic>) {
      // `/get` is exact on title+artist+duration — but only as exact as
      // the tags are. A 1.0 for a track tagged « 09 » by « <unknown> »
      // used to be a certainty; now it is 1.0 only when the folded
      // title and artist agree too, and it is capped at 0.80 when the
      // filename guess contradicts the query (DESIGN.md §3).
      final exactTitle = exact['trackName'];
      final exactArtist = exact['artistName'];
      final agrees =
          exactTitle is String &&
          exactArtist is String &&
          normalizeForConfidence(exactTitle) ==
              normalizeForConfidence(title) &&
          normalizeForConfidence(exactArtist) ==
              normalizeForConfidence(artist);
      var exactConfidence = agrees
          ? 1.0
          : _score(exact, title, artist, album, durationMs,
              filenameGuess: filenameGuess);
      if (filenameGuessContradictsQuery(
        filenameGuess,
        queryTitle: title,
        queryArtist: artist,
      )) {
        exactConfidence = exactConfidence.clamp(0.0, 0.80);
      }
      collect(exact, exactConfidence);
    } else if (exact != null) {
      exactFailure =
          LyricsSourceException(name, 'LRCLIB ne répond pas.', exact);
    }

    if (found is LyricsSourceException) {
      if (exactFailure != null) {
        // Both endpoints failed, so the source really is unusable. The exact
        // lookup's reason comes first: it was the earlier failure, and the
        // two are almost always the same cause anyway.
        throw exactFailure;
      }
      if (exact == null) {
        // /get wasn't attempted (no duration to match on) and /search
        // failed: nothing was collected, so the failure stands.
        throw found;
      }
      // /get delivered an exact match but /search failed: keep the exact
      // result instead of throwing it away. /search is only the broad
      // fallback here, and one dead endpoint must not discard good data.
    }

    if (found is List) {
      for (final item in found) {
        if (item is! Map<String, dynamic>) continue;
        collect(
          item,
          _score(item, title, artist, album, durationMs,
              filenameGuess: filenameGuess),
        );
      }
    }

    final results = [...byId.values, ...unidentified]
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return results;
  }

  /// One attempt at the request, plus exactly one retry on transient
  /// failures — a timeout, a dropped socket, a refused connection.
  ///
  /// A single failed request on a mobile network is not the source being down,
  /// so the retry keeps one from declaring it dead. The retry's own failure
  /// propagates as-is: this is one second chance, not a loop.
  Future<http.Response> _request(Uri uri) async {
    try {
      return await _send(uri);
    } on TimeoutException catch (_) {
      return _retryOnce(uri);
    } on SocketException catch (_) {
      return _retryOnce(uri);
    } on http.ClientException catch (_) {
      return _retryOnce(uri);
    }
  }

  Future<http.Response> _send(Uri uri) => _client
      .get(uri, headers: const {'User-Agent': _userAgent})
      .timeout(_timeout);

  /// The one retry, after a short pause. Any failure here is the answer.
  Future<http.Response> _retryOnce(Uri uri) async {
    await Future<void>.delayed(_retryDelay);
    return _send(uri);
  }

  /// Decodes one endpoint's body, or throws [LyricsSourceException].
  ///
  /// 404 comes back as null: for `/get` it is the documented "no match", which
  /// is an outcome rather than a failure.
  Future<Object?> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response = await _request(uri);
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

  /// Ranks a `/search` hit with the shared scorer (DESIGN.md §3).
  ///
  /// No floor: a hit that matches nothing scores 0, plus the synced
  /// bonus alone — the old 0.30 floor crowned false hits at 0.35.
  /// Accents are folded, so « Beyoncé » matches « Beyonce ».
  double _score(
    Map<String, dynamic> item,
    String title,
    String artist,
    String? album,
    int? durationMs, {
    FilenameGuess? filenameGuess,
  }) {
    final itemDuration = item['duration'];
    return scoreLyricsCandidate(
      candidateTitle: item['trackName'] is String
          ? item['trackName'] as String
          : '',
      candidateArtist: item['artistName'] is String
          ? item['artistName'] as String
          : '',
      candidateAlbum: item['albumName'] as String?,
      candidateDurationMs:
          itemDuration is num ? (itemDuration * 1000).round() : null,
      candidateHasSynced:
          item['syncedLyrics'] is String &&
          (item['syncedLyrics'] as String).trim().isNotEmpty,
      queryTitle: title,
      queryArtist: artist,
      queryAlbum: album,
      queryDurationMs: durationMs,
      filenameGuess: filenameGuess,
    ).total;
  }

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

    final duration = json['duration'];
    return LyricsSearchResult(
      source: name,
      title: json['trackName'] as String? ?? 'Titre inconnu',
      artist: json['artistName'] as String? ?? 'Artiste inconnu',
      album: json['albumName'] as String?,
      syncedLyrics: synced,
      unsyncedLyrics: unsynced,
      confidence: confidence,
      trackId: json['id'] is int ? json['id'] as int : null,
      durationMs: duration is num ? (duration * 1000).round() : null,
    );
  }
}
