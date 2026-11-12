// Tests de GeniusSource : recherche, appariement, scraping de la page,
// scores. Le réseau est simulé (MockClient) ; la vérification en direct
// se fait avec une sonde jetable, comme pour Kugou.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/providers/genius_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

const _page = '''
<html><body>
<div data-lyrics-container="true">
[Refrain]<br>Yeah, I&#39;m in the city<br>
You don&#39;t even have to do too much
</div>
</body></html>
''';

Map<String, Object?> _hit({
  String title = 'Blinding Lights',
  String artistNames = 'The Weeknd',
  String primary = 'The Weeknd',
  String url = 'https://genius.com/The-weeknd-blinding-lights-lyrics',
}) => {
  'id': 42,
  'title': title,
  'artist_names': artistNames,
  'primary_artist': {'name': primary},
  'url': url,
};

String _searchPayload(List<Map<String, Object?>> hits) => jsonEncode({
  'response': {
    'sections': [
      {
        'hits': [
          for (final hit in hits) {'result': hit},
        ],
      },
    ],
  },
});

MockClient _mockGenius({
  List<Map<String, Object?>> hits = const [],
  int searchStatus = 200,
  Map<String, String> pages = const {},
  List<int> pageStatuses = const [],
}) {
  var pageCalls = 0;
  return MockClient((request) async {
    if (request.url.host == 'genius.com' &&
        request.url.path == '/api/search/song') {
      // Response.bytes, pas Response : le constructeur String encode
      // en Latin-1 par défaut, et un titre non ASCII (« Française »)
      // deviendrait un octet UTF-8 invalide.
      return http.Response.bytes(
        utf8.encode(_searchPayload(hits)),
        searchStatus,
      );
    }
    if (request.url.host == 'genius.com') {
      final status = pageCalls < pageStatuses.length
          ? pageStatuses[pageCalls]
          : 200;
      pageCalls++;
      return http.Response.bytes(
        utf8.encode(pages[request.url.path] ?? ''),
        status,
      );
    }
    return http.Response('not found', 404);
  });
}

void main() {
  const queryTitle = 'Blinding Lights';
  const queryArtist = 'The Weeknd';

  Future<List<LyricsSearchResult>> search(GeniusSource source) =>
      source.search(title: queryTitle, artist: queryArtist);

  test('nominal : parole simple, score 0,80, marqueur gardé', () async {
    final source = GeniusSource(
      client: _mockGenius(
        hits: [_hit()],
        pages: {'/The-weeknd-blinding-lights-lyrics': _page},
      ),
    );

    final results = await search(source);

    expect(results, hasLength(1));
    final result = results.single;
    expect(result.source, 'Genius');
    expect(result.hasSyncedLyrics, isFalse);
    expect(result.hasUnsyncedLyrics, isTrue);
    expect(
      result.unsyncedLyrics!.text,
      '[Refrain]\n'
      "Yeah, I'm in the city\n"
      "You don't even have to do too much",
    );
    // 0,80 fixe : le seuil d'auto-intégration, pas plus (voir le
    // commentaire dans GeniusSource).
    expect(result.confidence, 0.80);
  });

  test('premier hit non correspondant : le deuxième est pris', () async {
    final source = GeniusSource(
      client: _mockGenius(
        hits: [
          _hit(
            title: 'Blinding Lights (Traduction Française)',
            artistNames: 'Genius Traductions Françaises',
            primary: 'Genius Traductions Françaises',
            url: 'https://genius.com/x-traduction',
          ),
          _hit(),
        ],
        pages: {'/The-weeknd-blinding-lights-lyrics': _page},
      ),
    );

    final results = await search(source);

    expect(results, hasLength(1));
    expect(results.single.unsyncedLyrics, isNotNull);
  });

  test('aucun hit correspondant : rien', () async {
    final source = GeniusSource(
      client: _mockGenius(
        hits: [_hit(artistNames: 'Dua Lipa', primary: 'Dua Lipa')],
      ),
    );

    expect(await search(source), isEmpty);
  });

  test('page 404 : le hit suivant est essayé', () async {
    final source = GeniusSource(
      client: _mockGenius(
        hits: [
          _hit(url: 'https://genius.com/premier'),
          _hit(url: 'https://genius.com/deuxieme'),
        ],
        pages: {'/deuxieme': _page},
        pageStatuses: [404, 200],
      ),
    );

    final results = await search(source);

    expect(results, hasLength(1));
  });

  test('page sans paroles : rien', () async {
    final source = GeniusSource(
      client: _mockGenius(
        hits: [_hit()],
        pages: {'/The-weeknd-blinding-lights-lyrics': '<html>vide</html>'},
      ),
    );

    expect(await search(source), isEmpty);
  });

  test('recherche 404 : rien', () async {
    final source = GeniusSource(
      client: _mockGenius(searchStatus: 404),
    );

    expect(await search(source), isEmpty);
  });

  test('recherche 500 : exception', () async {
    final source = GeniusSource(
      client: _mockGenius(searchStatus: 500),
    );

    await expectLater(
      search(source),
      throwsA(isA<LyricsSourceException>()),
    );
  });

  test('coupure réseau : 1 retry puis exception', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      throw const SocketException('coupé');
    });
    final source = GeniusSource(client: client);

    await expectLater(
      search(source),
      throwsA(isA<LyricsSourceException>()),
    );
    expect(calls, 2);
  });

  test('est une source de repli', () {
    expect(GeniusSource().isFallback, isTrue);
  });

  test('seul résultat : le mode IA l’intègre (bestAutoMatch)', () async {
    final source = GeniusSource(
      client: _mockGenius(
        hits: [_hit()],
        pages: {'/The-weeknd-blinding-lights-lyrics': _page},
      ),
    );

    final results = await search(source);

    expect(bestAutoMatch(results), results.single);
  });

  test('un résultat plus fort le devance (0,80, pas plus)', () async {
    final source = GeniusSource(
      client: _mockGenius(
        hits: [_hit()],
        pages: {'/The-weeknd-blinding-lights-lyrics': _page},
      ),
    );

    final results = await search(source);
    final stronger = LyricsSearchResult(
      source: 'LRCLIB',
      title: queryTitle,
      artist: queryArtist,
      unsyncedLyrics: const UnsyncedLyrics('Paroles'),
      confidence: 0.85,
    );

    expect(bestAutoMatch([stronger, ...results]), stronger);
  });
}
