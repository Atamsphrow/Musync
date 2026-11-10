// The tag-mtime cache: only real keys survive a reload.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/tag_mtime_store.dart';
import 'package:musync/features/library/data/music_scanner.dart';

void main() {
  late Directory dir;
  late TagMtimeStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('musync_mtimes_');
    store = TagMtimeStore(root: dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('only strings and legacy ints survive; junk is dropped', () async {
    await File(
      '${dir.path}${Platform.pathSeparator}tag_mtimes.json',
    ).writeAsString(
      jsonEncode({
        '/music/a.mp3': '123:456',
        '/music/b.mp3': 123456,
        '/music/c.mp3': null,
        '/music/d.mp3': [1, 2],
        '/music/e.mp3': {'x': 1},
        '/music/f.mp3': 12.5,
        '/music/g.mp3': true,
      }),
    );

    expect(await store.load(), {
      '/music/a.mp3': '123:456',
      // Old cache stored bare int mtimes: kept as text, which never matches
      // a "mtime:size" key and so forces exactly one re-read.
      '/music/b.mp3': '123456',
    });
  });

  test('le scanner purge les entrées de cache des morceaux disparus',
      () async {
    await store.save({'/ancien/a.mp3': '1:2'});
    final scanner = MusicScanner(mtimeStore: store);
    expect(await scanner.refreshMetadataFromFiles([]), isEmpty);
    expect(await store.load(), isEmpty);
  });

  test('a missing or corrupt file reads as empty, not an error', () async {
    expect(await store.load(), isEmpty);

    await File(
      '${dir.path}${Platform.pathSeparator}tag_mtimes.json',
    ).writeAsString('{ nope');
    expect(await store.load(), isEmpty);

    await File(
      '${dir.path}${Platform.pathSeparator}tag_mtimes.json',
    ).writeAsString('["not", "a", "map"]');
    expect(await store.load(), isEmpty);
  });
}
