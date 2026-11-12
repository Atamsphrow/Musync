import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/providers/genius_html.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

/// Genius as a plain-text fallback: the song's lyrics, scraped from its
/// page, when no synced source found anything.
///
/// Search (`/api/search/song`, no key) picks the right song; the song
/// page is then scraped for its lyrics containers. The idea (search,
/// matching, containers) is myspoti's `fromGenius` (`LyricsApi.kt`),
/// re-implemented in Dart from the idea (GPL-3.0 — no Kotlin was
/// copied).
///
/// A browser User-Agent on both requests: the page is served to
/// browsers, and the search is the site's own internal API.
class GeniusSource implements LyricsSource {
  static const String defaultBaseUrl = 'https://genius.com/api';

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36';

  static const Duration _timeout = Duration(seconds: 12);

  /// Pause before the single retry on a transient failure.
  static const Duration _retryDelay = Duration(seconds: 1);

  static const int _maxHits = 10;

  final http.Client _client;

  /// Where to send requests. The API root; the song pages are fetched
  /// from genius.com itself.
  final String baseUrl;

  /// The name shown next to results. The bundled entry carries the
  /// fixed default URL and name, so passing the config through is the
  /// same as the defaults.
  @override
  final String name;

  GeniusSource({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
    this.name = 'Genius',
  }) : _client = client ?? http.Client();

  /// The last resort: only asked when no synced lyrics came back.
  @override
  bool get isFallback => true;

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    final query = geniusQuery(title: title, artist: artist);
    if (query.isEmpty) return const [];
    final search = await _getJson(
      Uri.parse('$baseUrl/search/song').replace(
        queryParameters: {'per_page': '$_maxHits', 'q': query},
      ),
    );
    if (search == null) return const [];
    final hits = _sectionsHits(search);
    for (final hit in hits) {
      final result = hit['result'];
      if (result is! Map<String, dynamic>) continue;
      if (!geniusMatch(
        candidateTitle: _asString(result['title']),
        candidateArtists: _asString(result['artist_names']),
        primaryArtist: _primaryArtist(result),
        title: title,
        artist: artist,
      )) {
        continue;
      }
      final url = _asString(result['url']);
      if (url.isEmpty) continue;
      final page = await _getPage(Uri.parse(url));
      if (page == null) continue;
      final text = extractGeniusLyrics(page);
      if (text == null) continue;
      final lines = [
        for (final line in text.split('\n')) line.trim(),
      ].where((line) => line.isNotEmpty).toList();
      if (lines.isEmpty) continue;
      return [
        LyricsSearchResult(
          source: name,
          title: title,
          artist: artist,
          album: album,
          unsyncedLyrics: UnsyncedLyrics(lines.join('\n')),
          // Fixed at the auto-integrate threshold, and no higher: the
          // match is strict (equal titles, a shared artist), but there
          // is no duration to verify, so the shared scorer would give
          // 0.65. At 0.80 the AI mode integrates it on its own when it
          // is the only result — the user's call, 2026-11-12 — while a
          // genuinely stronger hit still outranks it.
          confidence: 0.80,
        ),
      ];
    }
    return const [];
  }

  /// The hits of the search response's first section, or empty when the
  /// shape is not what Genius sends.
  static List<Map<String, dynamic>> _sectionsHits(Object? json) {
    if (json is! Map<String, dynamic>) return const [];
    final response = json['response'];
    if (response is! Map<String, dynamic>) return const [];
    final sections = response['sections'];
    if (sections is! List || sections.isEmpty) return const [];
    final first = sections.first;
    if (first is! Map<String, dynamic>) return const [];
    final hits = first['hits'];
    if (hits is! List) return const [];
    return [
      for (final hit in hits)
        if (hit is Map<String, dynamic>) hit,
    ];
  }

  static String _primaryArtist(Map<String, dynamic> result) {
    final primary = result['primary_artist'];
    if (primary is Map<String, dynamic>) return _asString(primary['name']);
    return '';
  }

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

  /// Decodes the search response as JSON, or throws
  /// [LyricsSourceException]. 404 comes back as null: no match, which is
  /// an outcome rather than a failure.
  Future<Object?> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response = await _request(uri);
    } on TimeoutException catch (e) {
      throw LyricsSourceException(name, 'Genius ne répond pas.', e);
    } on SocketException catch (e) {
      throw LyricsSourceException(name, 'Pas de connexion internet.', e);
    } on http.ClientException catch (e) {
      throw LyricsSourceException(name, 'Connexion à Genius impossible.', e);
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw LyricsSourceException(
        name,
        'Genius a renvoyé une erreur (${response.statusCode}).',
      );
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (e) {
      throw LyricsSourceException(name, 'Réponse illisible de Genius.', e);
    }
  }

  /// The song page as text, or null when it cannot be read. A page that
  /// fails is skipped — the next hit is tried — never a failure of the
  /// whole search: the search itself already succeeded.
  Future<String?> _getPage(Uri uri) async {
    final http.Response response;
    try {
      response = await _request(uri);
    } on TimeoutException catch (_) {
      return null;
    } on SocketException catch (_) {
      return null;
    } on http.ClientException catch (_) {
      return null;
    }
    if (response.statusCode != 200) return null;
    return utf8.decode(response.bodyBytes);
  }

  static String _asString(Object? value) =>
      value is String ? value : '';
}
