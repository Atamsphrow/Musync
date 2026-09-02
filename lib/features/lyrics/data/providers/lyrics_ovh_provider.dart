/// lyrics.ovh — plain lyrics, and why that is worth having.
///
/// LRCLIB is community-sourced and strong where someone has bothered to time a
/// track. When it comes back empty there is nothing to fall back on, and the
/// user is left typing a lyric out by hand.
///
/// This source never returns timings. That is not the shortcoming it looks
/// like: Musync exists to *add* timings, and the sync editor's whole job is
/// turning words into a timed lyric. Handing it the words is most of the work
/// already done.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

class LyricsOvhSource implements LyricsSource {
  final http.Client _client;

  LyricsOvhSource({http.Client? client}) : _client = client ?? http.Client();

  @override
  String get name => 'lyrics.ovh';

  static const Duration _timeout = Duration(seconds: 12);

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
  }) async {
    // The endpoint takes the artist and title as path segments, so there is no
    // fuzzy matching to lean on: an empty artist can only ever 404.
    if (title.trim().isEmpty || artist.trim().isEmpty) return const [];

    final uri = Uri.https(
      'api.lyrics.ovh',
      '/v1/'
          '${Uri.encodeComponent(artist.trim())}/'
          '${Uri.encodeComponent(title.trim())}',
    );

    final http.Response response;
    try {
      response = await _client.get(uri).timeout(_timeout);
    } catch (e) {
      throw LyricsSourceException(
        name,
        'lyrics.ovh est injoignable. Vérifiez votre connexion.',
        e,
      );
    }

    // A miss, which is not a failure. Saying so lets the repository tell "no
    // result" apart from "the source is down" — the UI words them differently.
    if (response.statusCode == 404) return const [];

    if (response.statusCode != 200) {
      throw LyricsSourceException(
        name,
        'lyrics.ovh a répondu ${response.statusCode}.',
      );
    }

    final Object? decoded;
    try {
      // bodyBytes, not body: the `http` package falls back to latin-1 when the
      // server omits a charset, which turns every accent into mojibake — and
      // this source is at its most useful precisely on French titles.
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (e) {
      throw LyricsSourceException(name, 'Réponse illisible de lyrics.ovh.', e);
    }

    if (decoded is! Map) return const [];
    final text = decoded['lyrics'];
    if (text is! String || text.trim().isEmpty) return const [];

    return [
      LyricsSearchResult(
        source: name,
        // Echoed back from the request: the endpoint returns the lyric alone,
        // with nothing to correct the query against.
        title: title,
        artist: artist,
        album: album,
        unsyncedLyrics: UnsyncedLyrics(_tidy(text)),
        // Capped below LRCLIB on purpose.
        //
        // The path-segment lookup is effectively exact, so a hit is a good hit
        // — but it carries no timings, and a timed result should always sort
        // above an untimed one when both exist. The ranking is shared across
        // sources, so this is where that preference has to be expressed.
        confidence: 0.55,
      ),
    ];
  }

  /// Normalises line endings and trims the runs of blank lines the service
  /// leaves between sections.
  ///
  /// Every blank line becomes an empty entry in the sync editor, and an empty
  /// entry is a line the user has to skip past while stamping. Section markers
  /// like `[Refrain]` are kept — they belong to the lyric, and the editor knows
  /// how to leave them untimed.
  static String _tidy(String raw) {
    final lines = raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim());

    final out = <String>[];
    for (final line in lines) {
      if (line.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
      out.add(line);
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return out.join('\n');
  }
}
