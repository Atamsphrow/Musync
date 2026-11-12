import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/utils/text_search.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_confidence.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

/// NetEase Cloud Music (https://music.163.com) — free, no API key.
///
/// Two steps, both verified live 2026-11-12: `search/get` returns
/// songs with a name, artists, a duration in milliseconds and an id;
/// `song/lyric` returns the lyrics as LRC — line-synced, with a
/// Chinese translation (`tlyric`) and a romanization (`romalrc`) that
/// this source ignores (translation was refused by the user on
/// 2026-11-12; romanization was never asked for).
///
/// Each candidate must pass the strict `_sameSong` check (our title
/// and one of our artists, folded equal, duration within 4 s when
/// both are known) — a lyric fetch costs mobile data, and the wrong
/// song's words are worse than no words. The search often returns the
/// same song several times under different ids, so candidates are
/// deduplicated by (song, artist, duration) before anything is
/// downloaded. The survivors are scored with the shared scorer, the
/// best three get their lyrics fetched in parallel, and each parsed
/// LRC becomes its own result. A lyric that 404s or comes back empty
/// simply drops out — one bad hit must not take the good ones down
/// with it.
class NetEaseSource extends LyricsSource {
  /// The public instance.
  static const String defaultBaseUrl = 'https://music.163.com';

  static const String _userAgent =
      'Musync/1.0.0 (https://github.com/atamsphrow/musync)';

  static const Duration _timeout = Duration(seconds: 12);

  /// Pause before the single retry on a transient failure. One dropped request
  /// on a mobile network is routine; waiting a beat lets it go through.
  static const Duration _retryDelay = Duration(seconds: 1);

  /// How many search hits get their lyrics fetched. Three covers the usual
  /// shape — a clean version, a duplicate id, a live cut — without turning
  /// one lookup into a download spree on mobile data.
  static const int _maxLyricFetches = 3;

  /// A duration is close enough to be the same recording. The scorer
  /// draws its own line; this is the pre-filter's.
  static const int _durationToleranceMs = 4000;

  final http.Client _client;

  /// Where to send requests. Always a NetEase-shaped API.
  final String baseUrl;

  /// A final field satisfies the abstract getter on [LyricsSource], which keeps
  /// the name settable per instance without a second accessor.
  @override
  final String name;

  NetEaseSource({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
    this.name = 'NetEase',
  }) : _client = client ?? http.Client();

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    final json = await _getJson(
      Uri.parse('$baseUrl/api/search/get').replace(
        queryParameters: {
          's': '$title $artist',
          'type': '1',
          'limit': '6',
        },
      ),
    );
    if (json == null) return const [];
    if (json is! Map<String, dynamic>) {
      throw LyricsSourceException(name, 'Réponse inattendue de NetEase.');
    }
    final result = json['result'];
    if (result is! Map<String, dynamic>) return const [];
    final songs = result['songs'];
    if (songs is! List) return const [];

    final seen = <String>{};
    final scored = <_ScoredHit>[];
    for (final raw in songs) {
      if (raw is! Map<String, dynamic>) continue;
      final song = raw['name'];
      final artists = _artists(raw['artists']);
      final id = raw['id'];
      if (song is! String ||
          song.isEmpty ||
          artists.isEmpty ||
          id is! int) {
        continue;
      }
      final hitDurationMs = _asDurationMs(raw['duration']);
      // Same song under several ids: keep the first — the words are
      // the same recording's, and three near-identical NetEase rows
      // in the results list help nobody. The duration is rounded to
      // the second: two uploads of one master differ by tens of
      // milliseconds (170579 vs 170538 ms, seen live), while a
      // different cut is seconds away.
      final durationSeconds = hitDurationMs == null
          ? ''
          : '${hitDurationMs ~/ 1000}';
      if (!seen.add(
        '${foldForSearch(song)}|${foldForSearch(artists.first)}|$durationSeconds',
      )) {
        continue;
      }
      if (!_sameSong(
        song,
        artists,
        hitDurationMs,
        title,
        artist,
        durationMs,
      )) {
        continue;
      }
      scored.add(
        _ScoredHit(
          song: song,
          artist: artists.first,
          id: id,
          durationMs: hitDurationMs,
          selectionScore: scoreLyricsCandidate(
            candidateTitle: song,
            candidateArtist: artists.first,
            candidateAlbum: null,
            candidateDurationMs: hitDurationMs,
            candidateHasSynced: false,
            queryTitle: title,
            queryArtist: artist,
            queryAlbum: album,
            queryDurationMs: durationMs,
            filenameGuess: filenameGuess,
          ).total,
        ),
      );
    }
    // Nothing the search returned matches the query at all — fetching
    // lyrics for it would only download the wrong song's words.
    scored.removeWhere((hit) => hit.selectionScore <= 0);
    scored.sort((a, b) => b.selectionScore.compareTo(a.selectionScore));
    final picked = scored.take(_maxLyricFetches).toList();
    if (picked.isEmpty) return const [];

    final outcomes = await Future.wait([
      for (final hit in picked)
        _fetchHit(
          hit,
          queryTitle: title,
          queryArtist: artist,
          queryAlbum: album,
          queryDurationMs: durationMs,
          filenameGuess: filenameGuess,
        ).then<_FetchOutcome>(
          (result) => _FetchOutcome(result: result),
          onError: (Object error) => _FetchOutcome(error: error),
        ),
    ]);
    final results = [
      for (final outcome in outcomes)
        if (outcome.result != null) outcome.result!,
    ];
    if (results.isEmpty) {
      // Nothing usable came back: surface the first real failure, if any,
      // so "the source failed" stays distinguishable from "the source
      // knows nothing". When at least one hit produced a result, the
      // failures are swallowed — a result in hand beats an error about
      // the rest.
      for (final outcome in outcomes) {
        final error = outcome.error;
        if (error is LyricsSourceException) throw error;
      }
    }
    // The same recording under two ids returns the same words twice:
    // keep the best-scored copy.
    results.sort((a, b) => b.confidence.compareTo(a.confidence));
    return results;
  }

  /// Fetches and parses one hit's lyrics, or null when that hit has no
  /// usable lyrics. A 404 or an empty LRC is a dead hit, not a dead
  /// source. A real failure (the source down, a 500) propagates to
  /// [search], which decides whether to surface it or swallow it.
  Future<LyricsSearchResult?> _fetchHit(
    _ScoredHit hit, {
    required String queryTitle,
    required String queryArtist,
    String? queryAlbum,
    int? queryDurationMs,
    FilenameGuess? filenameGuess,
  }) async {
    final json = await _getJson(
      Uri.parse('$baseUrl/api/song/lyric').replace(
        queryParameters: {
          'id': '${hit.id}',
          'lv': '1',
          'kv': '1',
          'tv': '-1',
          'rv': '-1',
        },
      ),
    );
    if (json == null) return null;
    if (json is! Map<String, dynamic>) {
      throw LyricsSourceException(name, 'Réponse inattendue de NetEase.');
    }
    final lrc = json['lrc'];
    final raw = lrc is Map<String, dynamic> ? lrc['lyric'] : null;
    if (raw is! String || raw.trim().isEmpty) return null;
    // Credit lines ("作词 : …", "作曲 : …") come first in NetEase LRC.
    // Any line carrying " : " is one — a real lyric line with that
    // shape is rarer than a credit line without it.
    final parsed = LrcParser.parse(raw);
    final lines = [
      for (final line in parsed.lines)
        if (!line.text.contains(' : ')) line,
    ];
    if (lines.isEmpty) return null;
    final synced = lines.any(
      (l) => l.timestamp != null && l.timestamp! > Duration.zero,
    );
    final confidence = scoreLyricsCandidate(
      candidateTitle: hit.song,
      candidateArtist: hit.artist,
      candidateAlbum: null,
      candidateDurationMs: hit.durationMs,
      candidateHasSynced: synced,
      queryTitle: queryTitle,
      queryArtist: queryArtist,
      queryAlbum: queryAlbum,
      queryDurationMs: queryDurationMs,
      filenameGuess: filenameGuess,
    ).total;
    return LyricsSearchResult(
      source: name,
      title: queryTitle,
      artist: queryArtist,
      album: queryAlbum,
      syncedLyrics: synced ? SyncedLyrics(lines) : null,
      unsyncedLyrics: synced
          ? null
          : UnsyncedLyrics(lines.map((l) => l.text).join('\n')),
      confidence: confidence,
      trackId: hit.id,
      durationMs: hit.durationMs,
    );
  }

  /// The song's artists, folded for comparison, in order. The first is
  /// the one the scorer and the result carry.
  static List<String> _artists(Object? value) {
    if (value is! List) return const [];
    return [
      for (final raw in value)
        if (raw is Map<String, dynamic> &&
            raw['name'] is String &&
            (raw['name'] as String).isNotEmpty)
          raw['name'] as String,
    ];
  }

  /// Strict pre-filter: our title and one of our artists, folded
  /// equal, duration within tolerance when both are known. The title
  /// must be the same — "Hello Again" is not "Hello" — and the
  /// duration is what tells two recordings apart.
  static bool _sameSong(
    String song,
    List<String> artists,
    int? hitDurationMs,
    String queryTitle,
    String queryArtist,
    int? queryDurationMs,
  ) {
    if (foldForSearch(song) != foldForSearch(queryTitle)) return false;
    if (foldForSearch(queryArtist).isEmpty) return false;
    if (!artists.any(
      (a) => foldForSearch(a) == foldForSearch(queryArtist),
    )) {
      return false;
    }
    if (hitDurationMs != null &&
        queryDurationMs != null &&
        queryDurationMs > 0 &&
        (hitDurationMs - queryDurationMs).abs() > _durationToleranceMs) {
      return false;
    }
    return true;
  }

  static int? _asDurationMs(Object? value) =>
      value is num ? value.round() : null;

  /// One attempt at the request, plus exactly one retry on transient
  /// failures — a timeout, a dropped socket, a refused connection.
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

  Future<http.Response> _retryOnce(Uri uri) async {
    await Future<void>.delayed(_retryDelay);
    return _send(uri);
  }

  /// Decodes the response as JSON, or throws [LyricsSourceException].
  /// 404 comes back as null: no match, which is an outcome rather than
  /// a failure.
  Future<Object?> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response = await _request(uri);
    } on TimeoutException catch (e) {
      throw LyricsSourceException(name, 'NetEase ne répond pas.', e);
    } on SocketException catch (e) {
      throw LyricsSourceException(name, 'Pas de connexion internet.', e);
    } on http.ClientException catch (e) {
      throw LyricsSourceException(
        name,
        'Connexion à NetEase impossible.',
        e,
      );
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw LyricsSourceException(
        name,
        'NetEase a renvoyé une erreur (${response.statusCode}).',
      );
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (e) {
      throw LyricsSourceException(
        name,
        'Réponse illisible de NetEase.',
        e,
      );
    }
  }
}

class _ScoredHit {
  final String song;
  final String artist;
  final int id;
  final int? durationMs;
  final double selectionScore;

  const _ScoredHit({
    required this.song,
    required this.artist,
    required this.id,
    required this.durationMs,
    required this.selectionScore,
  });
}

class _FetchOutcome {
  final LyricsSearchResult? result;
  final Object? error;

  const _FetchOutcome({this.result, this.error});
}
