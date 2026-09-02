// The pieces added around searching: accent folding for the library filter,
// the plain-lyrics fallback source, and the bundled-source list.
//
// The HTTP source is driven through a MockClient rather than the real service:
// a test that needs the network is a test that fails on a train.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musync/core/utils/text_search.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_ovh_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/settings/data/lyrics_source_config.dart';

void main() {
  group('foldForSearch', () {
    test('matches in both directions across accents', () {
      // Nobody types `é` on a phone to find *Été*, and a tagger who wrote
      // *Maitre GIMS* should still turn up for `maître`.
      expect(foldForSearch('Été'), 'ete');
      expect(foldForSearch('Maître GIMS'), 'maitre gims');
      expect(foldForSearch('maitre gims'), 'maitre gims');
    });

    test('handles the ligatures French actually uses', () {
      expect(foldForSearch('Cœur'), 'coeur');
      expect(foldForSearch('Ærøskøbing'), 'aeroskobing');
    });

    test('leaves plain ASCII untouched', () {
      expect(foldForSearch('Panda'), 'panda');
      expect(foldForSearch('ROLL IN PEACE'), 'roll in peace');
    });

    test('leaves scripts it has no business rewriting alone', () {
      // Stripping marks outside Latin changes the word rather than normalising
      // it, so anything not in the table passes through.
      expect(foldForSearch('東京'), '東京');
      expect(foldForSearch('Привет'), 'привет');
    });
  });

  group('LyricsOvhSource', () {
    LyricsOvhSource sourceReturning(
      int status,
      String body, {
      void Function(http.Request)? inspect,
    }) {
      return LyricsOvhSource(
        client: MockClient((request) async {
          inspect?.call(request);
          return http.Response.bytes(utf8.encode(body), status, headers: {});
        }),
      );
    }

    test('returns the words, with no timings', () async {
      final source = sourceReturning(
        200,
        jsonEncode({'lyrics': 'Première ligne\nDeuxième ligne'}),
      );

      final results = await source.search(title: 'Corazon', artist: 'Gims');

      expect(results, hasLength(1));
      expect(results.single.hasSyncedLyrics, isFalse);
      expect(
        results.single.unsyncedLyrics!.text,
        'Première ligne\nDeuxième ligne',
      );
    });

    test('decodes UTF-8 even when the server omits the charset', () async {
      // `http` falls back to latin-1 without one, which would turn every accent
      // into mojibake — on a source whose whole value here is French titles.
      final source = sourceReturning(
        200,
        jsonEncode({'lyrics': 'Tu étais formidable'}),
      );

      final results = await source.search(
        title: 'Formidable',
        artist: 'Stromae',
      );

      expect(results.single.unsyncedLyrics!.text, 'Tu étais formidable');
    });

    test('a 404 is an empty answer, not a failure', () async {
      // The distinction matters: the repository only reports an error when
      // *every* source failed, and "nobody has this lyric" is not a failure.
      final source = sourceReturning(
        404,
        jsonEncode({'error': 'No lyrics found'}),
      );

      expect(await source.search(title: 'x', artist: 'y'), isEmpty);
    });

    test('a server error is reported as one', () async {
      final source = sourceReturning(500, 'boom');

      expect(
        () => source.search(title: 'x', artist: 'y'),
        throwsA(isA<LyricsSourceException>()),
      );
    });

    test('collapses blank runs but keeps section markers', () async {
      // Blank lines become empty rows the user has to stamp past in the editor.
      // `[Refrain]` is a different matter — it belongs to the lyric, and the
      // editor knows how to leave it untimed.
      final source = sourceReturning(
        200,
        jsonEncode({'lyrics': '[Refrain]\r\n\r\n\r\nUne\r\n\r\nDeux\r\n\r\n'}),
      );

      final results = await source.search(title: 'x', artist: 'y');

      expect(results.single.unsyncedLyrics!.text, '[Refrain]\n\nUne\n\nDeux');
    });

    test('refuses to ask without an artist', () async {
      // The endpoint takes artist and title as path segments — a missing one
      // can only ever 404, so there is no point spending a request on it.
      var called = false;
      final source = LyricsOvhSource(
        client: MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );

      expect(await source.search(title: 'Corazon', artist: '  '), isEmpty);
      expect(called, isFalse);
    });

    test('ranks below a timed result', () async {
      final source = sourceReturning(200, jsonEncode({'lyrics': 'Des mots'}));

      final results = await source.search(title: 'x', artist: 'y');

      // The ranking is shared across sources, so an untimed hit has to sit
      // under a timed one however exact the lookup was.
      expect(results.single.confidence, lessThan(1.0));
      expect(results.single.confidence, greaterThan(0.0));
    });
  });

  group('bundled sources', () {
    test('both are present, in order', () {
      expect(builtInSources.map((s) => s.id), ['lrclib', 'lyrics-ovh']);
      expect(builtInSources.every((s) => s.isBuiltIn), isTrue);
    });

    test(
      'kinds are distinct, and lrclib is the default for a stored record',
      () {
        expect(lrclibDefault.kind, LyricsSourceKind.lrclib);
        expect(lyricsOvhDefault.kind, LyricsSourceKind.lyricsOvh);

        // A record written before `kind` existed can only have been an LRCLIB
        // mirror — that was the only kind a user could add.
        final legacy = LyricsSourceConfig.fromJson({
          'id': 'custom-1',
          'name': 'Miroir',
          'baseUrl': 'https://miroir.example/api',
        });
        expect(legacy!.kind, LyricsSourceKind.lrclib);
      },
    );

    test('kind survives a JSON round trip', () {
      final decoded = LyricsSourceConfig.fromJson(
        jsonDecode(jsonEncode(lyricsOvhDefault.toJson())),
      );
      expect(decoded, lyricsOvhDefault);
    });
  });
}
