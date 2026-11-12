import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_confidence.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

/// LyricsPlus (https://lyricsplus.binimum.org) — free, no API key.
///
/// Timings come from Apple Music: word-by-word when the catalogue has them,
/// line-by-line otherwise, plain text when it has no timings at all for the
/// track. The `type` field says "Word" or "Line", but it is a claim, not a
/// guarantee — a track can arrive as `type: "Word"` with every timestamp at
/// zero and every `syllabus` empty (Tsota « Mahazo Tsirony »), which is
/// plain text, not timed lyrics. Only the concrete numbers decide, so the
/// classification below never trusts `type`.
class LyricsPlusSource extends LyricsSource {
  /// The public instance.
  static const String defaultBaseUrl =
      'https://lyricsplus.binimum.org/v2/lyrics';

  /// LyricsPlus asks clients to identify themselves so it can contact
  /// maintainers about misbehaving apps rather than just blocking them.
  static const String _userAgent =
      'Musync/1.0.0 (https://github.com/atamsphrow/musync)';

  static const Duration _timeout = Duration(seconds: 12);

  /// Pause before the single retry on a transient failure. One dropped request
  /// on a mobile network is routine; waiting a beat lets it go through.
  static const Duration _retryDelay = Duration(seconds: 1);

  final http.Client _client;

  /// Where to send requests. Always a LyricsPlus-shaped API.
  final String baseUrl;

  /// A final field satisfies the abstract getter on [LyricsSource], which keeps
  /// the name settable per instance without a second accessor.
  @override
  final String name;

  LyricsPlusSource({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
    this.name = 'LyricsPlus',
  }) : _client = client ?? http.Client();

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    // The API matches on duration: without it, a track it does know
    // answers 404 after ~10 s of searching its sources. No duration, no
    // request — the caller (and the repository) already ran the sources
    // that can answer without one.
    if (durationMs == null || durationMs <= 0) return const [];

    final json = await _getJson(
      Uri.parse('$baseUrl/get').replace(
        queryParameters: {
          'title': title,
          'artist': artist,
          'duration': (durationMs ~/ 1000).toString(),
        },
      ),
    );
    if (json == null) return const [];
    if (json is! Map<String, dynamic>) {
      throw LyricsSourceException(name, 'Réponse inattendue de LyricsPlus.');
    }
    final result = _toResult(
      json,
      title,
      artist,
      album,
      durationMs,
      filenameGuess,
    );
    return result == null ? const [] : [result];
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

  /// Decodes the endpoint's body, or throws [LyricsSourceException].
  ///
  /// 404 comes back as null: the documented "no match", which is an
  /// outcome rather than a failure.
  Future<Object?> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response = await _request(uri);
    } on TimeoutException catch (e) {
      throw LyricsSourceException(name, 'LyricsPlus ne répond pas.', e);
    } on SocketException catch (e) {
      throw LyricsSourceException(name, 'Pas de connexion internet.', e);
    } on http.ClientException catch (e) {
      throw LyricsSourceException(
        name,
        'Connexion à LyricsPlus impossible.',
        e,
      );
    }

    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw LyricsSourceException(
        name,
        'LyricsPlus a renvoyé une erreur (${response.statusCode}).',
      );
    }

    try {
      // utf8.decode over response.body: http falls back to latin-1 when the
      // server omits the charset, which mangles every accent.
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (e) {
      throw LyricsSourceException(name, 'Réponse illisible de LyricsPlus.', e);
    }
  }

  /// Builds the single result, or null when the entry carries no usable
  /// lyrics.
  ///
  /// Classification is on the numbers, never on `type`: a response is
  /// synced when at least one line carries a positive time or duration,
  /// or at least one word timing — a first line legitimately starts at
  /// 0 ms, so "every line at zero and every syllabus empty" is the only
  /// shape that means plain text. That shape must never become 26 lines
  /// stamped 00:00: the whole song would flash at once.
  LyricsSearchResult? _toResult(
    Map<String, dynamic> json,
    String queryTitle,
    String queryArtist,
    String? queryAlbum,
    int queryDurationMs,
    FilenameGuess? filenameGuess,
  ) {
    final metadata = json['metadata'];
    final rawLyrics = json['lyrics'];
    if (metadata is! Map<String, dynamic> || rawLyrics is! List) {
      return null;
    }

    final lines = <LyricLine>[];
    var anyTimed = false;
    var anyWords = false;
    for (final raw in rawLyrics) {
      if (raw is! Map<String, dynamic>) continue;
      final text = raw['text'];
      if (text is! String || text.trim().isEmpty) continue;
      final timeMs = _asMs(raw['time']);
      final durationMs = _asMs(raw['duration']);

      final words = <LyricWord>[];
      final syllabus = raw['syllabus'];
      if (syllabus is List) {
        for (final rawWord in syllabus) {
          if (rawWord is! Map<String, dynamic>) continue;
          final wordText = rawWord['text'];
          if (wordText is! String || wordText.trim().isEmpty) continue;
          words.add(
            LyricWord(
              start: Duration(milliseconds: _asMs(rawWord['time'])),
              duration: Duration(milliseconds: _asMs(rawWord['duration'])),
              text: wordText,
              isBackground: rawWord['isBackground'] == true,
            ),
          );
        }
      }

      if (timeMs > 0 || durationMs > 0 || words.isNotEmpty) anyTimed = true;
      if (words.isNotEmpty) anyWords = true;
      lines.add(
        LyricLine(
          timestamp: Duration(milliseconds: timeMs),
          text: text,
          words: List.unmodifiable(words),
        ),
      );
    }
    if (lines.isEmpty) return null;

    SyncedLyrics? synced;
    UnsyncedLyrics? unsynced;
    if (anyTimed) {
      synced = SyncedLyrics(lines);
      if (synced.isEmpty) return null;
    } else {
      unsynced = UnsyncedLyrics(lines.map((line) => line.text).join('\n'));
    }

    final candidateTitle = metadata['title'] is String
        ? metadata['title'] as String
        : '';
    final candidateArtist = metadata['artist'] is String
        ? metadata['artist'] as String
        : '';
    final candidateAlbum = metadata['album'] is String
        ? metadata['album'] as String
        : null;
    final candidateDurationMs = _parseTotalDuration(metadata['totalDuration']);

    // `/get` is exact on title+artist+duration — but only as exact as
    // the tags are. A 1.0 for a track tagged « 09 » by « <unknown> »
    // used to be a certainty; now it is capped at 0.80 when the
    // filename guess contradicts the query, like LRCLIB's `/get`.
    var confidence = scoreLyricsCandidate(
      candidateTitle: candidateTitle,
      candidateArtist: candidateArtist,
      candidateAlbum: candidateAlbum,
      candidateDurationMs: candidateDurationMs,
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
      title: candidateTitle.isEmpty ? 'Titre inconnu' : candidateTitle,
      artist: candidateArtist.isEmpty ? 'Artiste inconnu' : candidateArtist,
      album: candidateAlbum,
      syncedLyrics: synced,
      unsyncedLyrics: unsynced,
      confidence: confidence,
      durationMs: candidateDurationMs,
    );
  }

  /// A millisecond count, or 0 when the field is missing or nonsense.
  /// Negative values are floored: a timing before the start of the
  /// track is a broken payload, not a cue.
  static int _asMs(Object? value) {
    final ms = value is num ? value.toInt() : 0;
    return ms < 0 ? 0 : ms;
  }

  /// `totalDuration` arrives as `m:ss.mmm` ("2:50.539") or as an empty
  /// string when the source does not know it. A plain seconds number
  /// ("170.539") is accepted too. Null when unparseable: the duration
  /// component then simply scores 0.
  static int? _parseTotalDuration(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final colon = trimmed.indexOf(':');
    if (colon < 0) {
      final seconds = double.tryParse(trimmed);
      if (seconds == null || seconds < 0) return null;
      return (seconds * 1000).round();
    }
    final minutes = int.tryParse(trimmed.substring(0, colon));
    final seconds = double.tryParse(trimmed.substring(colon + 1));
    if (minutes == null || seconds == null || minutes < 0 || seconds < 0) {
      return null;
    }
    return ((minutes * 60 + seconds) * 1000).round();
  }
}
