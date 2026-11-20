// The listening history: what counts as a listen, how it is stored, and
// the two orders the « Historique » view shows.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/listening_history_store.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/listening_history_provider.dart';

Song _song(int id) => Song(
      id: id,
      title: 'T$id',
      artist: 'A',
      album: 'B',
      duration: 200000,
      filePath: '/music/$id.mp3',
    );

void main() {
  test('a listen is 30 s, or half of a track under a minute', () {
    expect(listenThreshold(const Duration(minutes: 4)),
        const Duration(seconds: 30));
    expect(listenThreshold(const Duration(seconds: 40)),
        const Duration(seconds: 20));
    expect(listenThreshold(Duration.zero), const Duration(seconds: 30));
  });

  test('the store round-trips and skips malformed entries', () async {
    final dir = await Directory.systemTemp.createTemp('musync_history_');
    addTearDown(() => dir.delete(recursive: true));
    final store = ListeningHistoryStore(root: dir);
    await store.save({
      '/a.mp3': const ListenEntry(count: 3, lastPlayedMs: 10),
    });
    expect(await store.load(), {
      '/a.mp3': const ListenEntry(count: 3, lastPlayedMs: 10),
    });

    await File('${dir.path}/listening_history.json').writeAsString(
      '{"/a.mp3": {"count": 2, "last": 5}, "/b.mp3": {"count": "x"}}',
    );
    expect((await store.load()).keys, ['/a.mp3']);
  });

  test('recent by last listen, most played by count', () {
    final songs = [_song(1), _song(2), _song(3)];
    final history = {
      '/music/1.mp3': const ListenEntry(count: 5, lastPlayedMs: 100),
      '/music/2.mp3': const ListenEntry(count: 1, lastPlayedMs: 300),
      '/gone.mp3': const ListenEntry(count: 9, lastPlayedMs: 999),
    };
    expect(
      historySongs(songs, history, byCount: false).map((s) => s.id),
      [2, 1],
    );
    expect(
      historySongs(songs, history, byCount: true).map((s) => s.id),
      [1, 2],
    );
  });

  test('listens recorded before the file loads are not lost', () async {
    final dir = await Directory.systemTemp.createTemp('musync_history_');
    addTearDown(() => dir.delete(recursive: true));
    await ListeningHistoryStore(root: dir).save({
      '/a.mp3': const ListenEntry(count: 1, lastPlayedMs: 1),
    });
    final container = ProviderContainer(
      overrides: [
        listeningHistoryStoreProvider.overrideWithValue(
          ListeningHistoryStore(root: dir),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(listeningHistoryProvider.notifier);
    await notifier.record('/a.mp3', atMs: 50);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      container.read(listeningHistoryProvider)['/a.mp3'],
      const ListenEntry(count: 2, lastPlayedMs: 50),
    );
  });

  test('a reload (import) reads the file again, never overwrites it', () async {
    final dir = await Directory.systemTemp.createTemp('musync_history_');
    addTearDown(() => dir.delete(recursive: true));
    final store = ListeningHistoryStore(root: dir);
    await store.save({'/old.mp3': const ListenEntry(count: 1, lastPlayedMs: 1)});
    final container = ProviderContainer(
      overrides: [listeningHistoryStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    container.read(listeningHistoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // An import writes the file, then invalidates the provider.
    await store.save({
      '/imported.mp3': const ListenEntry(count: 4, lastPlayedMs: 7),
    });
    container.invalidate(listeningHistoryProvider);
    container.read(listeningHistoryProvider);
    // A listen landing before the reload is kept, on top of the import.
    await container
        .read(listeningHistoryProvider.notifier)
        .record('/new.mp3', atMs: 9);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(listeningHistoryProvider), {
      '/imported.mp3': const ListenEntry(count: 4, lastPlayedMs: 7),
      '/new.mp3': const ListenEntry(count: 1, lastPlayedMs: 9),
    });
    expect(
      (await store.load()).keys,
      unorderedEquals(['/imported.mp3', '/new.mp3']),
    );
  });
}
