/// What Genius says about a song: its "About" text and the explanations
/// written on its lines.
///
/// Read from the JSON genius.com's own pages use (no key needed): a song
/// search, then the song and its annotations. The idea (endpoints,
/// matching, best-voted annotation, in-memory cache) is myspoti's
/// `GeniusMeaning.kt`, re-implemented in Dart from the idea (GPL-3.0 —
/// no Kotlin was copied). Shown in the original language — the user
/// refused machine translation on 2026-11-12, so no Google Translate
/// call is made here.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musync/core/utils/text_search.dart';

/// One line's explanation; [url] is its own page on Genius (empty when
/// Genius gave none).
class GeniusNote {
  final String fragment;
  final String explanation;
  final int votes;
  final String url;

  const GeniusNote({
    required this.fragment,
    required this.explanation,
    this.votes = 0,
    this.url = '',
  });
}

/// The meaning of a song: its "About" text and its lines' notes.
class GeniusMeaning {
  final String url;
  final String title;
  final String artist;
  final String? about;
  final List<GeniusNote> notes;

  const GeniusMeaning({
    required this.url,
    required this.title,
    required this.artist,
    this.about,
    required this.notes,
  });

  bool get isEmpty =>
      (about == null || about!.isEmpty) && notes.isEmpty;

  /// The note explaining [lineText], or null when no annotation covers
  /// it. A fragment matches when the folded line contains it, or it
  /// contains the folded line — Genius's fragments are snippets, rarely
  /// a whole line.
  GeniusNote? noteForLine(String lineText) {
    final line = foldForSearch(lineText);
    if (line.isEmpty) return null;
    for (final note in notes) {
      final fragment = foldForSearch(note.fragment);
      if (fragment.isEmpty) continue;
      if (line.contains(fragment) || fragment.contains(line)) return note;
    }
    return null;
  }
}

/// Thrown when Genius cannot be reached at all. "No meaning for this
/// song" is not an error — it is a null [GeniusMeaning].
class GeniusMeaningException implements Exception {
  final String message;
  const GeniusMeaningException(this.message);

  @override
  String toString() => message;
}

/// Genius meanings, fetched on demand and kept in memory.
///
/// The last few songs asked for are cached (small texts), including the
/// ones Genius knows nothing about — asking twice for the same song in
/// one session costs one request, not two.
class GeniusMeaningService {
  static const String defaultBaseUrl = 'https://genius.com/api';

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36';

  static const Duration _timeout = Duration(seconds: 12);

  /// Pause before the single retry on a transient failure.
  static const Duration _retryDelay = Duration(seconds: 1);

  /// How many meanings (and known absences) the cache keeps.
  static const int _cacheSize = 12;

  final http.Client _client;

  /// Where to send requests. Always a Genius-shaped API.
  final String baseUrl;

  final Map<String, GeniusMeaning?> _cache = {};

  GeniusMeaningService({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
  }) : _client = client ?? http.Client();

  /// The meaning of [title] by [artist], or null when no song on Genius
  /// matches, or it says nothing about it. Throws [GeniusMeaningException]
  /// when Genius cannot be reached.
  Future<GeniusMeaning?> find({
    required String title,
    required String artist,
  }) async {
    final key = '${foldForSearch(title)}|${foldForSearch(artist)}';
    if (_cache.containsKey(key)) return _cache[key];
    final meaning = await _findUncached(title: title, artist: artist);
    _cache[key] = meaning;
    while (_cache.length > _cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return meaning;
  }

  Future<GeniusMeaning?> _findUncached({
    required String title,
    required String artist,
  }) async {
    final cleanTitle = _cleanTitle(title);
    final artists = artist
        .split(RegExp(r'[, &]'))
        .map(foldForSearch)
        .where((a) => a.isNotEmpty)
        .toList();
    if (artists.isEmpty || cleanTitle.isEmpty) return null;
    final q = '$cleanTitle ${artist.split(',').first.trim()}';
    final search = await _getJson(
      Uri.parse('$baseUrl/search/song').replace(
        queryParameters: {'per_page': '5', 'q': q},
      ),
    );
    if (search == null) return null;
    final hits = _sectionsHits(search);
    // The right song: one of its artists, and its title (without
    // "feat." / "Remastered" asides).
    Map<String, dynamic>? song;
    for (final hit in hits) {
      final result = hit['result'];
      if (result is! Map<String, dynamic>) continue;
      final names = foldForSearch(_asString(result['artist_names']));
      final t = foldForSearch(_cleanTitle(_asString(result['title'])));
      final clean = foldForSearch(cleanTitle);
      if (names.isEmpty || t.isEmpty || clean.isEmpty) continue;
      if (!artists.any(names.contains)) continue;
      if (t == clean || t.startsWith(clean) || clean.startsWith(t)) {
        song = result;
        break;
      }
    }
    if (song == null) return null;
    final id = song['id'];
    if (id == null) return null;
    final results = await Future.wait([
      _getJson(
        Uri.parse('$baseUrl/songs/$id').replace(
          queryParameters: {'text_format': 'plain'},
        ),
      ),
      _getJson(
        Uri.parse('$baseUrl/referents').replace(
          queryParameters: {
            'song_id': '$id',
            'text_format': 'plain',
            'per_page': '50',
          },
        ),
      ),
    ]);
    final about = _aboutOf(results[0]);
    final notes = _notesOf(results[1]);
    final meaning = GeniusMeaning(
      url: _asString(song['url']),
      title: _asString(song['title']),
      artist: _asString(song['artist_names']),
      about: about,
      notes: notes,
    );
    return meaning.isEmpty ? null : meaning;
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

  /// The "About" text of a song response, or null when there is none.
  static String? _aboutOf(Object? json) {
    if (json == null) return null;
    if (json is! Map<String, dynamic>) return null;
    final response = json['response'];
    if (response is! Map<String, dynamic>) return null;
    final song = response['song'];
    if (song is! Map<String, dynamic>) return null;
    final description = song['description'];
    if (description is! Map<String, dynamic>) return null;
    final plain = _asString(description['plain']).trim();
    return plain.isNotEmpty && plain != '?' ? plain : null;
  }

  /// The lines' notes of a referents response. Genius's own "?" (empty)
  /// and the song-wide notes are left out: lines only. The best liked
  /// explanation of each line wins; one voted down (negative) is never
  /// shown.
  static List<GeniusNote> _notesOf(Object? json) {
    if (json == null) return const [];
    if (json is! Map<String, dynamic>) return const [];
    final response = json['response'];
    if (response is! Map<String, dynamic>) return const [];
    final referents = response['referents'];
    if (referents is! List) return const [];
    final notes = <GeniusNote>[];
    for (final raw in referents) {
      if (raw is! Map<String, dynamic>) continue;
      final fragment = _asString(raw['fragment']).trim();
      if (fragment.isEmpty) continue;
      final annotations = raw['annotations'];
      if (annotations is! List) continue;
      GeniusNote? best;
      for (final rawAnnotation in annotations) {
        if (rawAnnotation is! Map<String, dynamic>) continue;
        final body = rawAnnotation['body'];
        final bodyPlain = body is Map<String, dynamic>
            ? _asString(body['plain']).trim()
            : '';
        final votes = rawAnnotation['votes_total'] is num
            ? (rawAnnotation['votes_total'] as num).toInt()
            : 0;
        if (bodyPlain.isEmpty || bodyPlain == '?' || votes < 0) continue;
        if (best == null || votes > best.votes) {
          best = GeniusNote(
            fragment: fragment,
            explanation: bodyPlain,
            votes: votes,
            url: _asString(rawAnnotation['url']),
          );
        }
      }
      if (best != null) {
        notes.add(
          best.url.isEmpty
              ? GeniusNote(
                  fragment: best.fragment,
                  explanation: best.explanation,
                  votes: best.votes,
                  url: _asString(raw['url']),
                )
              : best,
        );
      }
    }
    return notes;
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

  /// Decodes the endpoint's body as JSON, or throws
  /// [GeniusMeaningException]. 404 comes back as null: no match, which is
  /// an outcome rather than a failure.
  Future<Object?> _getJson(Uri uri) async {
    final http.Response response;
    try {
      response = await _request(uri);
    } on TimeoutException {
      throw const GeniusMeaningException('Genius ne répond pas.');
    } on SocketException {
      throw const GeniusMeaningException('Pas de connexion internet.');
    } on http.ClientException {
      throw const GeniusMeaningException('Connexion à Genius impossible.');
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw GeniusMeaningException(
        'Genius a renvoyé une erreur (${response.statusCode}).',
      );
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const GeniusMeaningException('Réponse illisible de Genius.');
    }
  }

  /// The title without its asides: "(feat. …)", "- Remastered 2011",
  /// "[Live]".
  static String _cleanTitle(String title) => title
      .replaceAll(
        RegExp(
          r'\s*[(\[][^)\]]*(feat\.?|ft\.?|with|prod)[^)\]]*[)\]]',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(
          r'\s+-\s+.*(remaster|version|edit|live|mix|mono|stereo).*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();

  static String _asString(Object? value) =>
      value is String ? value : '';
}
