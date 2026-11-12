// Tests for the LyricsPlus source (step 1 of the myspoti plan).
//
// Everything here runs against a mocked HTTP client: the point is the
// parsing, the synced/plain classification and the scoring around the
// network, not LyricsPlus itself. Payloads mirror the real answers
// captured live on 2026-11-12 (Blinding Lights: word-timed; Juice WRLD
// « Scared of Love »: line-timed; Tsota « Mahazo Tsirony »: text only).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/data/providers/lyricsplus_provider.dart';

/// One LyricsPlus answer, in the shape the endpoint returns.
Map<String, dynamic> lpPayload({
  String type = 'Word',
  String title = 'Ma Chanson',
  String artist = 'Mon Artiste',
  String? album = 'Mon Album',
  String totalDuration = '3:20.000',
  List<Map<String, dynamic>>? lyrics,
}) => {
  'type': type,
  'metadata': {
    'title': title,
    'artist': artist,
    'album': album,
    'totalDuration': totalDuration,
    'source': 'qApple',
    'language': 'fr',
    'isrc': 'FR0000000001',
  },
  'lyrics':
      lyrics ??
      [
        {
          'time': 1000,
          'duration': 2000,
          'text': 'Une ligne',
          'syllabus': [
            {
              'time': 1000,
              'duration': 500,
              'text': 'Une',
              'isBackground': false,
            },
            {
              'time': 1500,
              'duration': 500,
              'text': 'ligne',
              'isBackground': false,
            },
          ],
          'element': {'singer': ''},
        },
      ],
};

/// A line in the Juice WRLD shape: timed, no word timings.
Map<String, dynamic> lineOnly({
  int time = 4008,
  int duration = 1982,
  String text = 'Ooh, ooh, whoa',
}) => {
  'time': time,
  'duration': duration,
  'text': text,
  'syllabus': [],
  'element': {'singer': ''},
};

/// A line in the Tsota shape: type "Word" on paper, zero timings in fact.
Map<String, dynamic> allZero({String text = 'Aieyii'}) => {
  'time': 0,
  'duration': 0,
  'text': text,
  'syllabus': [],
  'element': {'singer': ''},
};

/// Serves `/get` from the given payload.
///
/// Responses are built with `Response.bytes` and no content-type, which is
/// how the endpoint actually answers — and the case where `http`'s `.body`
/// falls back to latin-1 and mangles every accent.
MockClient mockLyricsPlus({
  Object? payload,
  int status = 200,
  List<Uri>? recordInto,
  int failTimes = 0,
}) {
  var calls = 0;
  return MockClient((request) async {
    recordInto?.add(request.url);
    calls++;
    if (calls <= failTimes) {
      throw const SocketException('Connexion réinitialisée');
    }
    if (status != 200) return http.Response('', status);
    return http.Response.bytes(utf8.encode(jsonEncode(payload)), 200);
  });
}

void main() {
  const query = (
    title: 'Ma Chanson',
    artist: 'Mon Artiste',
    durationMs: 200000,
  );

  group('LyricsPlusSource', () {
    test('mot à mot : lignes + mots parsés, confiance 0,90', () async {
      final source = LyricsPlusSource(
        client: mockLyricsPlus(payload: lpPayload()),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(results, hasLength(1));
      final result = results.single;
      expect(result.source, 'LyricsPlus');
      expect(result.hasSyncedLyrics, isTrue);
      expect(result.hasWordTimings, isTrue);
      final line = result.syncedLyrics!.lines.single;
      expect(line.timestamp, const Duration(milliseconds: 1000));
      expect(line.text, 'Une ligne');
      expect(line.words, hasLength(2));
      expect(line.words[0].text, 'Une');
      expect(line.words[0].start, const Duration(milliseconds: 1000));
      expect(line.words[0].duration, const Duration(milliseconds: 500));
      expect(line.words[1].text, 'ligne');
      // 0,35 + 0,30 + 0,15 (durée 3:20 exacte) + 0,05 (synchro) + 0,05 (mots).
      expect(result.confidence, closeTo(0.90, 0.001));
      expect(result.durationMs, 200000);
    });

    test('lignes calées sans mots : synchro, pas de mot à mot, 0,85', () async {
      final source = LyricsPlusSource(
        client: mockLyricsPlus(
          payload: lpPayload(
            type: 'Line',
            totalDuration: '2:50.539',
            lyrics: [
              lineOnly(),
              lineOnly(time: 9946, text: 'I never been'),
            ],
          ),
        ),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: 171000,
      );
      expect(results, hasLength(1));
      final result = results.single;
      expect(result.hasSyncedLyrics, isTrue);
      expect(result.hasWordTimings, isFalse);
      expect(result.syncedLyrics!.length, 2);
      expect(result.durationMs, 170539);
      // 0,35 + 0,30 + 0,15 (2:50.539 ≈ 171 s) + 0,05 (synchro).
      expect(result.confidence, closeTo(0.85, 0.001));
    });

    test('tout à zéro : texte seul, jamais 26 lignes à 00:00', () async {
      final source = LyricsPlusSource(
        client: mockLyricsPlus(
          payload: lpPayload(
            totalDuration: '',
            lyrics: [
              allZero(),
              allZero(text: 'Ny Olombelona'),
            ],
          ),
        ),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(results, hasLength(1));
      final result = results.single;
      expect(result.hasSyncedLyrics, isFalse);
      expect(result.hasWordTimings, isFalse);
      expect(result.hasUnsyncedLyrics, isTrue);
      expect(result.unsyncedLyrics!.text, 'Aieyii\nNy Olombelona');
      // 0,35 + 0,30, sans durée (totalDuration vide) ni synchro.
      expect(result.confidence, closeTo(0.65, 0.001));
    });

    test('première ligne à 0 ms + mots : calée quand même', () async {
      final source = LyricsPlusSource(
        client: mockLyricsPlus(
          payload: lpPayload(
            lyrics: [
              {
                'time': 0,
                'duration': 2000,
                'text': 'Intro',
                'syllabus': [
                  {
                    'time': 0,
                    'duration': 500,
                    'text': 'In',
                    'isBackground': false,
                  },
                  {
                    'time': 500,
                    'duration': 500,
                    'text': 'tro',
                    'isBackground': false,
                  },
                ],
                'element': {'singer': ''},
              },
            ],
          ),
        ),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(results.single.hasSyncedLyrics, isTrue);
      expect(results.single.hasWordTimings, isTrue);
    });

    test('404 = rien trouvé, pas une erreur', () async {
      final source = LyricsPlusSource(
        client: mockLyricsPlus(payload: null, status: 404),
      );
      expect(
        await source.search(
          title: query.title,
          artist: query.artist,
          durationMs: query.durationMs,
        ),
        isEmpty,
      );
    });

    test('500 = LyricsSourceException', () async {
      final source = LyricsPlusSource(
        client: mockLyricsPlus(payload: null, status: 500),
      );
      await expectLater(
        source.search(
          title: query.title,
          artist: query.artist,
          durationMs: query.durationMs,
        ),
        throwsA(isA<LyricsSourceException>()),
      );
    });

    test('JSON illisible = LyricsSourceException', () async {
      final source = LyricsPlusSource(
        client: MockClient(
          (_) async => http.Response.bytes(utf8.encode('pas du json'), 200),
        ),
      );
      await expectLater(
        source.search(
          title: query.title,
          artist: query.artist,
          durationMs: query.durationMs,
        ),
        throwsA(isA<LyricsSourceException>()),
      );
    });

    test('sans durée : aucune requête, liste vide', () async {
      final seen = <Uri>[];
      final source = LyricsPlusSource(
        client: mockLyricsPlus(payload: lpPayload(), recordInto: seen),
      );
      expect(
        await source.search(title: query.title, artist: query.artist),
        isEmpty,
      );
      expect(seen, isEmpty);
    });

    test('requête : /get avec titre, artiste, durée en secondes', () async {
      final seen = <Uri>[];
      final source = LyricsPlusSource(
        client: mockLyricsPlus(payload: lpPayload(), recordInto: seen),
      );
      await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(seen, hasLength(1));
      expect(seen.single.path, endsWith('/get'));
      expect(seen.single.queryParameters['title'], query.title);
      expect(seen.single.queryParameters['artist'], query.artist);
      expect(seen.single.queryParameters['duration'], '200');
    });

    test('devinette nom de fichier contradictoire : plafonné à 0,80', () async {
      final source = LyricsPlusSource(
        client: mockLyricsPlus(payload: lpPayload()),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
        filenameGuess: (artist: 'Autre', title: 'Autre Titre'),
      );
      expect(results.single.confidence, closeTo(0.80, 0.001));
    });

    test('une coupure réseau : un retry, puis le résultat', () async {
      final source = LyricsPlusSource(
        client: mockLyricsPlus(payload: lpPayload(), failTimes: 1),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(results, hasLength(1));
    });

    test('deux coupures : LyricsSourceException', () async {
      final source = LyricsPlusSource(
        client: mockLyricsPlus(payload: lpPayload(), failTimes: 2),
      );
      await expectLater(
        source.search(
          title: query.title,
          artist: query.artist,
          durationMs: query.durationMs,
        ),
        throwsA(isA<LyricsSourceException>()),
      );
    });

    test('payload sans paroles : liste vide', () async {
      final source = LyricsPlusSource(
        client: mockLyricsPlus(
          payload: {
            'type': 'Word',
            'metadata': {'title': 'Ma Chanson', 'artist': 'Mon Artiste'},
            'lyrics': [],
          },
        ),
      );
      expect(
        await source.search(
          title: query.title,
          artist: query.artist,
          durationMs: query.durationMs,
        ),
        isEmpty,
      );
    });
  });
}
