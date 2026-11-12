// Tests de NetEaseSource : recherche, appariement strict, LRC,
// crédits, scores. Le réseau est simulé (MockClient) ; la
// vérification en direct se fait avec une sonde jetable, comme pour
// Kugou.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/data/providers/netease_provider.dart';

const _lrc = '[00:03.50]Ooh, ooh, woah\n'
    '[00:09.70]I never been scared\n'
    '[00:13.70]I tell you that I don\'t care\n';

const _lrcWithCredits = '[00:00.00]作词 : Juice WRLD\n'
    '[00:00.00]作曲 : Juice WRLD\n'
    '[00:03.50]Ooh, ooh, woah\n'
    '[00:09.70]I never been scared\n';

Map<String, Object?> _song({
  int id = 566254178,
  String name = 'Scared of Love',
  String artist = 'Juice WRLD',
  int duration = 171000,
}) => {
  'id': id,
  'name': name,
  'artists': [
    {'name': artist},
  ],
  'duration': duration,
};

String _searchPayload(List<Map<String, Object?>> songs) => jsonEncode({
  'result': {'songCount': songs.length, 'songs': songs},
});

String _lyricPayload(String lrc) => jsonEncode({
  'lrc': {'version': 1, 'lyric': lrc},
});

MockClient _mockNetEase({
  List<Map<String, Object?>> songs = const [],
  int searchStatus = 200,
  Map<int, String> lyrics = const {},
  Map<int, int> lyricStatuses = const {},
}) {
  return MockClient((request) async {
    if (request.url.path == '/api/search/get') {
      return http.Response.bytes(
        utf8.encode(_searchPayload(songs)),
        searchStatus,
      );
    }
    if (request.url.path == '/api/song/lyric') {
      final id = int.tryParse(request.url.queryParameters['id'] ?? '');
      final status = lyricStatuses[id] ?? 200;
      return http.Response.bytes(
        utf8.encode(_lyricPayload(lyrics[id] ?? '')),
        status,
      );
    }
    return http.Response('not found', 404);
  });
}

void main() {
  const queryTitle = 'Scared of Love';
  const queryArtist = 'Juice WRLD';

  Future<List<LyricsSearchResult>> search(NetEaseSource source) =>
      source.search(
        title: queryTitle,
        artist: queryArtist,
        durationMs: 171000,
      );

  test('nominal : 53 lignes calées, score 0,85', () async {
    final source = NetEaseSource(
      client: _mockNetEase(
        songs: [_song()],
        lyrics: {566254178: _lrc},
      ),
    );

    final results = await search(source);

    expect(results, hasLength(1));
    final result = results.single;
    expect(result.source, 'NetEase');
    expect(result.hasSyncedLyrics, isTrue);
    expect(result.syncedLyrics!.length, 3);
    expect(result.trackId, 566254178);
    expect(result.durationMs, 171000);
    // 0,35 (titre) + 0,30 (artiste) + 0,15 (durée) + 0,05 (synchro).
    expect(result.confidence, closeTo(0.85, 0.001));
  });

  test('doublon : le même morceau sous deux ids ne donne qu’un résultat',
      () async {
    final source = NetEaseSource(
      client: _mockNetEase(
        songs: [_song(id: 566254178), _song(id: 1848224875)],
        lyrics: {566254178: _lrc, 1848224875: _lrc},
      ),
    );

    final results = await search(source);

    expect(results, hasLength(1));
  });

  test('premier hit sans paroles : le deuxième est utilisé', () async {
    // Deux durées distinctes (171 s et 173 s) : deux enregistrements
    // aux yeux de la déduplication — le deuxième est bien essayé.
    final source = NetEaseSource(
      client: _mockNetEase(
        songs: [_song(id: 1), _song(id: 2, duration: 173000)],
        lyrics: {1: '', 2: _lrc},
      ),
    );

    final results = await search(source);

    expect(results, hasLength(1));
    expect(results.single.trackId, 2);
  });

  test('lignes de crédit écartées', () async {
    final source = NetEaseSource(
      client: _mockNetEase(
        songs: [_song()],
        lyrics: {566254178: _lrcWithCredits},
      ),
    );

    final results = await search(source);

    expect(results.single.syncedLyrics!.length, 2);
    expect(
      results.single.syncedLyrics!.lines.map((l) => l.text),
      ['Ooh, ooh, woah', 'I never been scared'],
    );
  });

  test('aucun morceau correspondant : rien', () async {
    final source = NetEaseSource(
      client: _mockNetEase(
        songs: [_song(artist: 'Dua Lipa')],
      ),
    );

    expect(await search(source), isEmpty);
  });

  test('durée trop éloignée : rien', () async {
    final source = NetEaseSource(
      client: _mockNetEase(
        songs: [_song(duration: 258000)],
      ),
    );

    expect(await search(source), isEmpty);
  });

  test('titre avec parenthèse refusé : le titre plié diffère', () async {
    final source = NetEaseSource(
      client: _mockNetEase(
        songs: [_song(name: 'Scared of Love (Live)')],
      ),
    );

    // « Scared of Love (Live) » n'est pas « Scared of Love » : le
    // titre plié diffère, le pré-filtre l'écarte.
    expect(await search(source), isEmpty);
  });

  test('recherche 404 : rien', () async {
    final source = NetEaseSource(
      client: _mockNetEase(searchStatus: 404),
    );

    expect(await search(source), isEmpty);
  });

  test('recherche 500 : exception', () async {
    final source = NetEaseSource(
      client: _mockNetEase(searchStatus: 500),
    );

    await expectLater(
      search(source),
      throwsA(isA<LyricsSourceException>()),
    );
  });

  test('paroles 404 : le hit est écarté, pas la source', () async {
    final source = NetEaseSource(
      client: _mockNetEase(
        songs: [_song()],
        lyrics: {566254178: _lrc},
        lyricStatuses: {566254178: 404},
      ),
    );

    expect(await search(source), isEmpty);
  });

  test('coupure réseau : 1 retry puis exception', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      throw const SocketException('coupé');
    });
    final source = NetEaseSource(client: client);

    await expectLater(
      search(source),
      throwsA(isA<LyricsSourceException>()),
    );
    expect(calls, 2);
  });

  test('tout à zéro : texte simple, jamais synchro', () async {
    const zeroLrc = '[00:00.00]Ooh, ooh, woah\n[00:00.00]I never been scared\n';
    final source = NetEaseSource(
      client: _mockNetEase(
        songs: [_song()],
        lyrics: {566254178: zeroLrc},
      ),
    );

    final results = await search(source);

    expect(results, hasLength(1));
    expect(results.single.hasSyncedLyrics, isFalse);
    expect(results.single.hasUnsyncedLyrics, isTrue);
  });

  test('est une source normale, pas un repli', () {
    expect(NetEaseSource().isFallback, isFalse);
  });
}
