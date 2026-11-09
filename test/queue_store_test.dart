// The named-queues store: one corrupt entry must not wipe every queue.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/named_queue.dart';
import 'package:musync/features/player/data/queue_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song song(int id, String path) => Song(
  id: id,
  title: 'Titre $id',
  artist: 'Artiste',
  album: 'Album',
  duration: 60000,
  filePath: path,
);

void main() {
  test('a corrupt entry is dropped, the valid queues survive', () async {
    final good = NamedQueue(
      id: 'q1',
      name: 'Bonne file',
      songs: [song(1, '/a.mp3')],
    );
    // Wrong-typed fields: `id` as an int throws inside `fromJson`
    // (`as String?`), which used to abort the whole loop and drop every
    // queue.
    final corrupt = {'id': 123, 'name': 'Cassée', 'songs': []};
    SharedPreferences.setMockInitialValues({
      'named_queues_v1': jsonEncode([good.toJson(), corrupt]),
      'named_queues_active_v1': 'q1',
    });

    final loaded = await QueueStore().load();

    expect(loaded.queues.map((q) => q.id).toList(), ['q1']);
    expect(loaded.activeId, 'q1');
  });

  test('a corrupt document still reads as empty', () async {
    SharedPreferences.setMockInitialValues({
      'named_queues_v1': 'not json{',
    });

    final loaded = await QueueStore().load();

    expect(loaded.queues, isEmpty);
  });

  test('save then load round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    final store = QueueStore();
    final queues = [
      NamedQueue(
        id: 'q1',
        name: 'Première',
        songs: [song(1, '/a.mp3'), song(2, '/b.mp3')],
        currentIndex: 1,
      ),
    ];
    await store.save(queues, 'q1');

    final loaded = await store.load();

    expect(loaded.queues.length, 1);
    expect(loaded.queues.first.name, 'Première');
    expect(loaded.queues.first.currentIndex, 1);
    expect(loaded.activeId, 'q1');
  });
}
