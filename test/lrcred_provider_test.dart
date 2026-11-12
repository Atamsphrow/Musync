// Tests for the lrc.red source (step 2 of the myspoti plan).
//
// Everything here runs against a mocked HTTP client: the point is the
// search → TTML flow, the synced/plain classification and the scoring
// around the network, not lrc.red itself. Payloads mirror the real answers
// captured live on 2026-11-12 (Juice WRLD « Scared of Love »: line-timed;
// Tsota « Mahazo Tsirony »: text only; two hits on the Juice search, the
// clean version and the instrumental one).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musync/features/lyrics/data/providers/lrcred_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

/// One lrc.red search hit, in the shape search.json returns it.
Map<String, dynamic> hit({
  String isrc = 'USUG12102466',
  String title = 'Scared of Love',
  String artist = 'Juice WRLD',
  String? album = 'Goodbye & Good Riddance',
  double duration = 170.539,
}) => {
  'isrc': isrc,
  'title': title,
  'artist': artist,
  'album': album,
  'year': 2018,
  'duration': duration,
  'cover': 'https://lrc.red/s/USUG12102466.webp',
};

/// A TTML answer in the Juice shape: line timings, no word timings.
String lineTtml({String first = 'Ooh, ooh, whoa'}) =>
    '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:lrc="http://lrc.red/lyric-ttml-internal" lrc:timing="Line" xml:lang="en">'
    '<body dur="2:50.539"><div>'
    '<p begin="4.008" end="8.526">$first</p>'
    '<p begin="9.946" end="11.928">I never been scared</p>'
    '</div></body></tt>';

/// A TTML answer in the Tsota shape: plain `<p>`, no timings at all.
const plainTtml =
    '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:lrc="http://lrc.red/lyric-ttml-internal" lrc:timing="None" xml:lang="tl">'
    '<body><div>'
    '<p>Aieyii ...aieyaa...aieyii..</p>'
    '<p>Ny Olombelona oa samy misy maso</p>'
    '</div></body></tt>';

/// A TTML answer with word timings.
const wordTtml =
    '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
    '<p begin="1.000" end="3.000">'
    '<span begin="1.000" end="1.500">Une</span> '
    '<span begin="1.500" end="2.000">ligne</span>'
    '</p></div></body></tt>';

/// Serves search.json from [hits] and `/s/{isrc}.ttml` from [ttmlByIsrc].
///
/// Responses are built with `Response.bytes` and no content-type, which is
/// how the endpoint actually answers — and the case where `http`'s `.body`
/// falls back to latin-1 and mangles every accent.
MockClient mockLrcRed({
  List<Map<String, dynamic>>? hits,
  Map<String, String>? ttmlByIsrc,
  Map<String, int>? ttmlStatusByIsrc,
  int searchStatus = 200,
  Object? searchPayload,
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
    final path = request.url.path;
    if (path.endsWith('/search.json')) {
      if (searchStatus != 200) return http.Response('', searchStatus);
      final payload = searchPayload ?? {'hits': hits ?? [], 'next': null};
      return http.Response.bytes(utf8.encode(jsonEncode(payload)), 200);
    }
    if (path.contains('/s/') && path.endsWith('.ttml')) {
      final isrc = path.split('/').last.replaceAll('.ttml', '');
      final status = ttmlStatusByIsrc?[isrc] ?? 200;
      if (status != 200) return http.Response('', status);
      final ttml = (ttmlByIsrc ?? const {})[isrc] ?? lineTtml();
      return http.Response.bytes(utf8.encode(ttml), 200);
    }
    return http.Response('', 404);
  });
}

void main() {
  const query = (
    title: 'Scared of Love',
    artist: 'Juice WRLD',
    durationMs: 171000,
  );

  group('LrcRedSource', () {
    test('lignes calées : synchro, pas de mot à mot, 0,85', () async {
      final source = LrcRedSource(
        client: mockLrcRed(hits: [hit()]),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(results, hasLength(1));
      final result = results.single;
      expect(result.source, 'lrc.red');
      expect(result.hasSyncedLyrics, isTrue);
      expect(result.hasWordTimings, isFalse);
      expect(result.syncedLyrics!.length, 2);
      expect(result.syncedLyrics!.lines.first.timestamp,
          const Duration(milliseconds: 4008));
      expect(result.durationMs, 170539);
      // 0,35 + 0,30 + 0,15 (170,539 s ≈ 171 s) + 0,05 (synchro).
      expect(result.confidence, closeTo(0.85, 0.001));
    });

    test('texte seul : jamais de lignes à 00:00, 0,80', () async {
      final source = LrcRedSource(
        client: mockLrcRed(
          hits: [
            hit(
              isrc: 'CH6541963556',
              title: 'Mahazo Tsirony',
              artist: 'Tsota',
              album: null,
              duration: 227.0,
            ),
          ],
          ttmlByIsrc: const {'CH6541963556': plainTtml},
        ),
      );
      final results = await source.search(
        title: 'Mahazo Tsirony',
        artist: 'Tsota',
        durationMs: 227000,
      );
      expect(results, hasLength(1));
      final result = results.single;
      expect(result.hasSyncedLyrics, isFalse);
      expect(result.hasWordTimings, isFalse);
      expect(result.hasUnsyncedLyrics, isTrue);
      expect(
        result.unsyncedLyrics!.text,
        'Aieyii ...aieyaa...aieyii..\nNy Olombelona oa samy misy maso',
      );
      // 0,35 + 0,30 + 0,15 (227 s exactes), sans synchro.
      expect(result.confidence, closeTo(0.80, 0.001));
    });

    test('mot à mot : mots parsés, 0,90', () async {
      final source = LrcRedSource(
        client: mockLrcRed(
          hits: [hit(title: 'Ma Chanson', artist: 'Mon Artiste')],
          ttmlByIsrc: const {'USUG12102466': wordTtml},
        ),
      );
      final results = await source.search(
        title: 'Ma Chanson',
        artist: 'Mon Artiste',
        durationMs: 171000,
      );
      expect(results, hasLength(1));
      final result = results.single;
      expect(result.hasSyncedLyrics, isTrue);
      expect(result.hasWordTimings, isTrue);
      expect(result.syncedLyrics!.lines.single.words, hasLength(2));
      // 0,35 + 0,30 + 0,15 (durée) + 0,05 (synchro) + 0,05 (mots).
      expect(result.confidence, closeTo(0.90, 0.001));
    });

    test('deux hits : les deux reviennent, le meilleur d\'abord', () async {
      final source = LrcRedSource(
        client: mockLrcRed(
          hits: [
            hit(),
            hit(
              isrc: 'USUG12102467',
              title: 'Scared of Love (with instrumental by Ghost Loft)',
            ),
          ],
        ),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(results, hasLength(2));
      expect(results[0].confidence, closeTo(0.85, 0.001));
      // Titre partiel : 0,15 + 0,30 + 0,15 + 0,05 (synchro).
      expect(results[1].confidence, closeTo(0.65, 0.001));
      expect(results[1].title, contains('instrumental'));
    });

    test('TTML 404 du meilleur hit : le second revient quand même', () async {
      final source = LrcRedSource(
        client: mockLrcRed(
          hits: [
            hit(),
            hit(
              isrc: 'USUG12102467',
              title: 'Scared of Love (with instrumental by Ghost Loft)',
            ),
          ],
          ttmlStatusByIsrc: const {'USUG12102466': 404},
        ),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(results, hasLength(1));
      expect(results.single.title, contains('instrumental'));
    });

    test('tous les TTML en 404 : liste vide, pas une erreur', () async {
      final source = LrcRedSource(
        client: mockLrcRed(
          hits: [hit()],
          ttmlStatusByIsrc: const {'USUG12102466': 404},
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

    test('recherche 404 = rien trouvé, pas une erreur', () async {
      final source = LrcRedSource(
        client: mockLrcRed(hits: [hit()], searchStatus: 404),
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

    test('recherche 500 = LyricsSourceException', () async {
      final source = LrcRedSource(
        client: mockLrcRed(hits: [hit()], searchStatus: 500),
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

    test('JSON recherche illisible = LyricsSourceException', () async {
      final source = LrcRedSource(
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

    test('sans durée : la recherche part quand même', () async {
      final seen = <Uri>[];
      final source = LrcRedSource(
        client: mockLrcRed(hits: [hit()], recordInto: seen),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
      );
      expect(results, hasLength(1));
      expect(seen, hasLength(2));
      expect(seen.first.path, endsWith('/search.json'));
      // 0,35 + 0,30, sans durée ni (durée inconnue) — synchro 0,05.
      expect(results.single.confidence, closeTo(0.70, 0.001));
    });

    test('requête : search.json puis /s/{isrc}.ttml', () async {
      final seen = <Uri>[];
      final source = LrcRedSource(
        client: mockLrcRed(hits: [hit()], recordInto: seen),
      );
      await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(seen, hasLength(2));
      expect(seen[0].path, endsWith('/search.json'));
      expect(seen[0].queryParameters['q'], 'Scared of Love Juice WRLD');
      expect(seen[1].path, endsWith('/s/USUG12102466.ttml'));
    });

    test('aucun hit ne correspond : aucun TTML fetché', () async {
      final seen = <Uri>[];
      final source = LrcRedSource(
        client: mockLrcRed(
          hits: [
            // Titre et artiste étrangers, durée loin aussi : le score de
            // sélection tombe à 0, et aucun TTML n'est téléchargé.
            hit(
              title: 'Tout Autre Chose',
              artist: 'Quelqu\'un D\'autre',
              duration: 60.0,
            ),
          ],
          recordInto: seen,
        ),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(results, isEmpty);
      expect(seen, hasLength(1));
      expect(seen.single.path, endsWith('/search.json'));
    });

    test('devinette nom de fichier contradictoire : plafonné à 0,80', () async {
      final source = LrcRedSource(
        client: mockLrcRed(hits: [hit()]),
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
      final source = LrcRedSource(
        client: mockLrcRed(hits: [hit()], failTimes: 1),
      );
      final results = await source.search(
        title: query.title,
        artist: query.artist,
        durationMs: query.durationMs,
      );
      expect(results, hasLength(1));
    });

    test('deux coupures : LyricsSourceException', () async {
      final source = LrcRedSource(
        client: mockLrcRed(hits: [hit()], failTimes: 2),
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
  });
}
