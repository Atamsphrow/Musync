import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/player/data/playback_state_store.dart';

void main() {
  late Directory tmp;

  PlaybackStateStore store() {
    PlaybackStateStore.debugResetForTest();
    return PlaybackStateStore(
      fileLocator: () async => File('${tmp.path}/playback_state.json'),
    );
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('playback_state_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
    PlaybackStateStore.debugResetForTest();
  });

  test('empty store reads as defaults', () async {
    final state = await store().load();
    expect(state.queuePaths, isEmpty);
    expect(state.index, 0);
    expect(state.shuffle, isFalse);
    expect(state.repeat, 'off');
    expect(state.bubbleActive, isFalse);
  });

  test('round trip keeps every field', () async {
    final s = store();
    await s.update(
      queuePaths: ['/a.mp3', '/b.mp3', '/c.mp3'],
      index: 2,
      shuffle: true,
      repeat: 'all',
      bubbleActive: true,
    );
    // Fresh instance, memory cleared: must come back from disk.
    final loaded = await store().load();
    expect(loaded.queuePaths, ['/a.mp3', '/b.mp3', '/c.mp3']);
    expect(loaded.index, 2);
    expect(loaded.shuffle, isTrue);
    expect(loaded.repeat, 'all');
    expect(loaded.bubbleActive, isTrue);
  });

  test('updates merge: writers do not clobber each other', () async {
    final s = store();
    await s.update(queuePaths: ['/a.mp3'], index: 0);
    // A second writer (the bubble controller) only touches its own field.
    await s.update(bubbleActive: true);
    final loaded = await store().load();
    expect(loaded.queuePaths, ['/a.mp3']);
    expect(loaded.bubbleActive, isTrue);
  });

  test('corrupt file reads as defaults, next update heals it', () async {
    final file = File('${tmp.path}/playback_state.json');
    await file.writeAsString('not json{');
    PlaybackStateStore.debugResetForTest();
    final fresh = PlaybackStateStore(
      fileLocator: () async => file,
    );
    final state = await fresh.load();
    expect(state.queuePaths, isEmpty);
    await fresh.update(index: 3);
    final healed = await store().load();
    expect(healed.index, 0); // clamped: queue is empty
  });

  test('index is clamped to the queue', () async {
    final s = store();
    await s.update(queuePaths: ['/a.mp3'], index: 99);
    final loaded = await store().load();
    expect(loaded.index, 0);
  });

  test('unknown repeat reads as off', () async {
    final s = store();
    await s.update(repeat: 'sometimes');
    final loaded = await store().load();
    expect(loaded.repeat, 'off');
  });
}
