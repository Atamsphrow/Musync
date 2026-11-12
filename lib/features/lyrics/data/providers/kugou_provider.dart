import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/utils/text_search.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_confidence.dart';
import 'package:musync/features/lyrics/data/providers/krc.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

/// Kugou (https://lyrics.kugou.com) — free, no API key.
///
/// Two steps, both verified live 2026-11-12: `search` returns candidates
/// with a song, a singer, a duration in milliseconds, an id and an
/// accesskey; `download` returns the lyrics as KRC — an encrypted format
/// (see [decryptKrc]) with word timings when the catalogue has them.
///
/// The search often returns the same song three times under different
/// ids, so candidates are deduplicated by (song, singer, duration) before
/// anything is downloaded. Each candidate must also pass the strict
/// `sameSong` check (one of our artists, our title or a prefix of it,
/// duration within 4 s when both are known) — a KRC download costs mobile
/// data, and a wrong cut's word timings are worse than no timings. The
/// survivors are scored with the shared scorer, the best three get their
/// KRC fetched in parallel, and each parsed KRC becomes its own candidate,
/// re-scored with the synced and word-timing signals. A KRC that 404s or
/// does not parse simply drops out — one bad hit must not take the good
/// ones down with it.
class KugouSource extends LyricsSource {
  /// The public instance.
  static const String defaultBaseUrl = 'https://lyrics.kugou.com';

  static const String _userAgent =
      'Musync/1.0.0 (https://github.com/atamsphrow/musync)';

  static const Duration _timeout = Duration(seconds: 12);

  /// Pause before the single retry on a transient failure. One dropped request
  /// on a mobile network is routine; waiting a beat lets it go through.
  static const Duration _retryDelay = Duration(seconds: 1);

  /// How many search hits get their KRC fetched. Three covers the usual
  /// shape — a clean version, an instrumental, a live cut — without turning
  /// one lookup into a download spree on mobile data.
  static const int _maxKrcFetches = 3;

  final http.Client _client;

  /// Where to send requests. Always a Kugou-shaped API.
  final String baseUrl;

  /// A final field satisfies the abstract getter on [LyricsSource], which keeps
  /// the name settable per instance without a second accessor.
  @override
  final String name;

  KugouSource({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
    this.name = 'Kugou',
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
      Uri.parse('$baseUrl/search').replace(
        queryParameters: {
          'ver': '1',
          'man': 'yes',
          'client': 'pc',
          'keyword': '$artist - $title',
          if (durationMs != null && durationMs > 0)
            'duration': '$durationMs',
        },
      ),
    );
    if (json == null) return const [];
    if (json is! Map<String, dynamic>) {
      throw LyricsSourceException(name, 'Réponse inattendue de Kugou.');
    }
    final candidates = json['candidates'];
    if (candidates is! List) return const [];

    final seen = <String>{};
    final scored = <_ScoredHit>[];
    for (final raw in candidates) {
      if (raw is! Map<String, dynamic>) continue;
      final song = raw['song'];
      final singer = raw['singer'];
      final id = raw['id'];
      final accesskey = raw['accesskey'];
      if (song is! String ||
          singer is! String ||
          id is! String ||
          accesskey is! String ||
          song.isEmpty ||
          singer.isEmpty ||
          id.isEmpty ||
          accesskey.isEmpty) {
        continue;
      }
      final hitDurationMs = _asDurationMs(raw['duration']);
      // Same song under several ids: keep the first, the KRC is the same.
      if (!seen.add(
        '${foldForSearch(song)}|${foldForSearch(singer)}|${hitDurationMs ?? ''}',
      )) {
        continue;
      }
      if (!_sameSong(
        song,
        singer,
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
          singer: singer,
          id: id,
          accesskey: accesskey,
          durationMs: hitDurationMs,
          selectionScore: scoreLyricsCandidate(
            candidateTitle: song,
            candidateArtist: singer,
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
    // KRC for it would only download the wrong song's lyrics.
    scored.removeWhere((hit) => hit.selectionScore <= 0);
    scored.sort((a, b) => b.selectionScore.compareTo(a.selectionScore));
    final picked = scored.take(_maxKrcFetches).toList();
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
    results.sort((a, b) => b.confidence.compareTo(a.confidence));
    return results;
  }

  /// Fetches and parses one hit's KRC, or null when that hit has no usable
  /// lyrics. A 404 or an unparseable KRC is a dead hit, not a dead source.
  /// A real failure (the source down, a 500) propagates to [search], which
  /// decides whether to surface it or swallow it.
  Future<LyricsSearchResult?> _fetchHit(
    _ScoredHit hit, {
    required String queryTitle,
    required String queryArtist,
    String? queryAlbum,
    int? queryDurationMs,
    FilenameGuess? filenameGuess,
  }) async {
    final json = await _getJson(
      Uri.parse('$baseUrl/download').replace(
        queryParameters: {
          'ver': '1',
          'client': 'pc',
          'id': hit.id,
          'accesskey': hit.accesskey,
          'fmt': 'krc',
          'charset': 'utf8',
        },
      ),
    );
    if (json == null) return null;
    if (json is! Map<String, dynamic>) {
      throw LyricsSourceException(name, 'Réponse inattendue de Kugou.');
    }
    final content = json['content'];
    if (content is! String || content.isEmpty) return null;
    final krc = decryptKrc(content);
    if (krc == null) return null;
    final lines = parseKrcLyrics(krc, song: hit.song, singer: hit.singer);
    if (lines == null) return null;
    return _toResult(
      lines,
      hit,
      queryTitle,
      queryArtist,
      queryAlbum,
      queryDurationMs,
      filenameGuess,
    );
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

  /// Decodes the endpoint's body as JSON, or throws [LyricsSourceException].
  ///
  /// 404 comes back as null: the documented "no match", which is an
  /// outcome rather than a failure.
  Future<Object?> _getJson(Uri uri) async {
    final response = await _getResponse(uri);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw LyricsSourceException(
        name,
        'Kugou a renvoyé une erreur (${response.statusCode}).',
      );
    }

    try {
      // utf8.decode over response.body: http falls back to latin-1 when the
      // server omits the charset, which mangles every accent.
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (e) {
      throw LyricsSourceException(name, 'Réponse illisible de Kugou.', e);
    }
  }

  Future<http.Response> _getResponse(Uri uri) async {
    final http.Response response;
    try {
      response = await _request(uri);
    } on TimeoutException catch (e) {
      throw LyricsSourceException(name, 'Kugou ne répond pas.', e);
    } on SocketException catch (e) {
      throw LyricsSourceException(name, 'Pas de connexion internet.', e);
    } on http.ClientException catch (e) {
      throw LyricsSourceException(name, 'Connexion à Kugou impossible.', e);
    }
    return response;
  }

  /// Builds the result for one parsed KRC, or null when the lines carry
  /// nothing (defensive: the parser already filters those out).
  ///
  /// Classification is on the numbers, never on a flag: a response is
  /// synced when at least one line carries a positive time or at least one
  /// word timing — a first line legitimately starts at 0 ms, so "every
  /// line untimed and no words" is the only shape that means plain text.
  /// That shape must never become 26 lines stamped 00:00: the whole song
  /// would flash at once.
  LyricsSearchResult? _toResult(
    List<LyricLine> lines,
    _ScoredHit hit,
    String queryTitle,
    String queryArtist,
    String? queryAlbum,
    int? queryDurationMs,
    FilenameGuess? filenameGuess,
  ) {
    var anyTimed = false;
    var anyWords = false;
    for (final line in lines) {
      if (line.timestamp != null && line.timestamp!.inMilliseconds > 0) {
        anyTimed = true;
      }
      if (line.words.isNotEmpty) {
        anyTimed = true;
        anyWords = true;
      }
    }

    SyncedLyrics? synced;
    UnsyncedLyrics? unsynced;
    if (anyTimed) {
      synced = SyncedLyrics(lines);
      if (synced.isEmpty) return null;
    } else {
      unsynced = UnsyncedLyrics(lines.map((line) => line.text).join('\n'));
    }

    // A search hit is only as exact as the tags are. A 1.0 for a track
    // tagged « 09 » by « <unknown> » used to be a certainty; now it is
    // capped at 0.80 when the filename guess contradicts the query, like
    // LRCLIB's `/get` and LyricsPlus.
    var confidence = scoreLyricsCandidate(
      candidateTitle: hit.song,
      candidateArtist: hit.singer,
      candidateAlbum: null,
      candidateDurationMs: hit.durationMs,
      candidateHasSynced: synced != null,
      candidateHasWordTimings: anyWords,
      queryTitle: queryTitle,
      queryArtist: queryArtist,
      queryAlbum: queryAlbum,
      queryDurationMs: queryDurationMs,
      filenameGuess: filenameGuess,
    ).total;
    if (filenameGuessContradictsQuery(
      filenameGuess,
      queryTitle: queryTitle,
      queryArtist: queryArtist,
    )) {
      confidence = confidence.clamp(0.0, 0.80);
    }

    return LyricsSearchResult(
      source: name,
      title: hit.song.isEmpty ? 'Titre inconnu' : hit.song,
      artist: hit.singer.isEmpty ? 'Artiste inconnu' : hit.singer,
      album: null,
      syncedLyrics: synced,
      unsyncedLyrics: unsynced,
      confidence: confidence,
      durationMs: hit.durationMs,
    );
  }

  /// A duration in milliseconds (the search hit shape), as milliseconds.
  /// Null when missing or nonsense: the duration component then simply
  /// scores 0.
  static int? _asDurationMs(Object? value) {
    if (value is! num) return null;
    final ms = value.round();
    return ms < 0 ? null : ms;
  }
}

/// The same song for Kugou: one of its singers is ours, the title is ours
/// (either may carry extras), and the length is within 4 s when both are
/// known. The scorer alone is too soft here — a wrong cut's KRC would
/// otherwise be downloaded, and its word timings would then be trusted.
bool _sameSong(
  String candSong,
  String candSinger,
  int? candDurationMs,
  String title,
  String artist,
  int? durationMs,
) {
  if (foldForSearch(artist).isEmpty) return false;
  final singers = candSinger.split(RegExp(r'[, &、/]+'))..add(candSinger);
  if (!singers.any(
    (s) => s.trim().isNotEmpty && foldForSearch(s) == foldForSearch(artist),
  )) {
    return false;
  }
  final t = foldForSearch(title);
  final ct = foldForSearch(candSong);
  if (t.isEmpty || !(ct == t || ct.startsWith(t) || t.startsWith(ct))) {
    return false;
  }
  return durationMs == null ||
      durationMs <= 0 ||
      candDurationMs == null ||
      candDurationMs <= 0 ||
      (candDurationMs - durationMs).abs() <= 4000;
}

/// One search hit, with the score that decided whether its KRC is worth
/// fetching. The synced and word-timing signals only exist after the KRC
/// is parsed, so the selection score is title + artist + album + duration
/// only — the final score is computed again in [_toResult].
class _ScoredHit {
  final String song;
  final String singer;
  final String id;
  final String accesskey;
  final int? durationMs;
  final double selectionScore;

  const _ScoredHit({
    required this.song,
    required this.singer,
    required this.id,
    required this.accesskey,
    required this.durationMs,
    required this.selectionScore,
  });
}

/// One KRC fetch's outcome: a result, nothing (404, unparseable), or a
/// real failure. Held so [KugouSource.search] can decide whether a failure
/// is worth surfacing once every hit has been tried.
class _FetchOutcome {
  final LyricsSearchResult? result;
  final Object? error;

  const _FetchOutcome({this.result, this.error});
}
