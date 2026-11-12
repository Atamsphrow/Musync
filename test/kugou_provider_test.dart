// Tests de la source Kugou (4e source du plan myspoti).
//
// Tout tourne contre un client HTTP simulé : le point est le flux
// recherche -> KRC, la déduplication, l'appariement strict et le score
// autour du réseau, pas Kugou lui-même. Les charges reflètent les
// réponses réelles capturées en live le 2026-11-12 (Blinding Lights :
// 3 candidats identiques, KRC mot à mot ; Lucid Dreams : idem).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musync/features/lyrics/data/providers/kugou_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

/// Chiffre un texte KRC comme le fait Kugou (miroir de decryptKrc).
String encryptKrc(String text) {
  const key = [
    64,
    71,
    97,
    119,
    94,
    50,
    116,
    71,
    81,
    54,
    49,
    45,
    206,
    210,
    110,
    105,
  ];
  final compressed = ZLibEncoder().convert(utf8.encode(text));
  final xored = List<int>.generate(
    compressed.length,
    (i) => compressed[i] ^ key[i % key.length],
  );
  return base64Encode([0, 0, 0, 0, ...xored]);
}

/// Un KRC minimal mot à mot (titre + crédits + 3 lignes).
String krcText({
  String song = 'Blinding Lights',
  String singer = 'The Weeknd',
}) =>
    '[ti:$song]\n'
    '[ar:$singer]\n'
    '[0,1756]<0,439,0>$song - <878,439,0>$singer\n'
    '[1757,4829]<0,439,0>Lyrics <439,439,0>by：<878,439,0>Max\n'
    '[14075,13597]<0,177,0>Yeah\n'
    '[27672,2784]<0,200,0>I\'ve <200,144,0>been <344,176,0>tryna <520,632,0>call\n'
    '[30456,2720]<0,184,0>I\'ve <184,177,0>been <361,191,0>on <552,176,0>my <728,273,0>own <1001,239,0>for <1240,352,0>long\n';

/// Un candidat de recherche Kugou, dans la forme renvoyée.
Map<String, dynamic> hit({
  String song = 'Blinding Lights',
  String singer = 'The Weeknd',
  int duration = 200097,
  String id = '821332895',
  String accesskey = 'cle-test',
}) => {
  'song': song,
  'singer': singer,
  'duration': duration,
  'id': id,
  'accesskey': accesskey,
};

/// Sert la recherche depuis [hits] et le téléchargement depuis
/// [krcById] (texte KRC brut, chiffré ici). Les réponses sont
/// construites en octets sans content-type, comme le fait l'endpoint.
MockClient mockKugou({
  List<Map<String, dynamic>>? hits,
  Map<String, String>? krcById,
  Map<String, int>? downloadStatusById,
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
    if (path.endsWith('/search')) {
      if (searchPayload != null) {
        return http.Response.bytes(
          utf8.encode(jsonEncode(searchPayload)),
          searchStatus,
        );
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode({'candidates': hits ?? []})),
        searchStatus,
      );
    }
    if (path.endsWith('/download')) {
      final id = request.url.queryParameters['id'] ?? '';
      final status = downloadStatusById?[id] ?? 200;
      final krc = krcById?[id];
      if (krc == null && status == 200) {
        return http.Response.bytes(
          utf8.encode(jsonEncode({'content': ''})),
          200,
        );
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode({'content': encryptKrc(krc ?? '')})),
        status,
      );
    }
    return http.Response.bytes(utf8.encode('{}'), 404);
  });
}

void main() {
  Future<List<LyricsSearchResult>> search(
    MockClient client, {
    String title = 'Blinding Lights',
    String artist = 'The Weeknd',
    int? durationMs = 200000,
  }) => KugouSource(client: client).search(
    title: title,
    artist: artist,
    durationMs: durationMs,
  );

  test('chemin nominal : 1 résultat synchro mot à mot', () async {
    final client = mockKugou(
      hits: [hit()],
      krcById: {'821332895': krcText()},
    );
    final results = await search(client);
    expect(results, hasLength(1));
    final result = results.single;
    expect(result.source, 'Kugou');
    expect(result.title, 'Blinding Lights');
    expect(result.artist, 'The Weeknd');
    expect(result.hasSyncedLyrics, isTrue);
    expect(result.hasWordTimings, isTrue);
    expect(result.confidence, greaterThan(0.85));
    expect(result.durationMs, 200097);
    expect(result.syncedLyrics!.lines.map((l) => l.text), [
      'Yeah',
      "I've been tryna call",
      "I've been on my own for long",
    ]);
  });

  test('3 candidats identiques : un seul téléchargement', () async {
    final urls = <Uri>[];
    final client = mockKugou(
      hits: [
        hit(id: '1'),
        hit(id: '2'),
        hit(id: '3'),
      ],
      krcById: {'1': krcText()},
      recordInto: urls,
    );
    final results = await search(client);
    expect(results, hasLength(1));
    expect(urls.where((u) => u.path.endsWith('/download')), hasLength(1));
  });

  test('chanteur différent : rien, sans télécharger', () async {
    final urls = <Uri>[];
    final client = mockKugou(
      hits: [hit(singer: 'Autre Artiste')],
      krcById: {'821332895': krcText()},
      recordInto: urls,
    );
    expect(await search(client), isEmpty);
    expect(urls.where((u) => u.path.endsWith('/download')), isEmpty);
  });

  test('durée à 10 s : rien, sans télécharger', () async {
    final urls = <Uri>[];
    final client = mockKugou(
      hits: [hit(duration: 210000)],
      krcById: {'821332895': krcText()},
      recordInto: urls,
    );
    expect(await search(client), isEmpty);
    expect(urls.where((u) => u.path.endsWith('/download')), isEmpty);
  });

  test('titre avec précision accepté (préfixe)', () async {
    final client = mockKugou(
      hits: [hit(song: 'Blinding Lights (Remaster)')],
      krcById: {'821332895': krcText()},
    );
    final results = await search(client);
    expect(results, hasLength(1));
  });

  test('recherche 404 : liste vide', () async {
    final client = mockKugou(searchStatus: 404, searchPayload: {});
    expect(await search(client), isEmpty);
  });

  test('recherche 500 : exception', () async {
    final client = mockKugou(searchStatus: 500, searchPayload: {});
    await expectLater(search(client), throwsA(isA<LyricsSourceException>()));
  });

  test('téléchargement 404 : candidat écarté', () async {
    final client = mockKugou(
      hits: [hit()],
      downloadStatusById: {'821332895': 404},
    );
    expect(await search(client), isEmpty);
  });

  test('KRC illisible : candidat écarté', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/search')) {
        return http.Response.bytes(
          utf8.encode(jsonEncode({'candidates': [hit()]})),
          200,
        );
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode({'content': '!!!pas-du-base64!!!'})),
        200,
      );
    });
    expect(await search(client), isEmpty);
  });

  test('KRC trop court (< 3 lignes) : candidat écarté', () async {
    const short =
        '[14075,13597]<0,177,0>Yeah\n'
        '[27672,2784]<0,200,0>I\'ve <200,144,0>been\n';
    final client = mockKugou(hits: [hit()], krcById: {'821332895': short});
    expect(await search(client), isEmpty);
  });

  test('1er appel coupé : le retry passe', () async {
    final client = mockKugou(
      hits: [hit()],
      krcById: {'821332895': krcText()},
      failTimes: 1,
    );
    expect(await search(client), hasLength(1));
  });

  test('la durée n’est envoyée que quand elle est connue', () async {
    final urls = <Uri>[];
    final client = mockKugou(
      hits: [hit()],
      krcById: {'821332895': krcText()},
      recordInto: urls,
    );
    await KugouSource(client: client).search(
      title: 'Blinding Lights',
      artist: 'The Weeknd',
    );
    final searchUrl = urls.singleWhere((u) => u.path.endsWith('/search'));
    expect(searchUrl.queryParameters.containsKey('duration'), isFalse);
  });

  test('nom de fichier contradictoire : confiance plafonnée à 0,80',
      () async {
    final client = mockKugou(
      hits: [hit()],
      krcById: {'821332895': krcText()},
    );
    final results = await KugouSource(client: client).search(
      title: 'Blinding Lights',
      artist: 'The Weeknd',
      durationMs: 200000,
      filenameGuess: (artist: 'Autre', title: 'Autre Titre'),
    );
    expect(results, hasLength(1));
    expect(results.single.confidence, lessThanOrEqualTo(0.80));
  });
}
