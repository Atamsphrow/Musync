// Replacing a file's contents, safely and without racing itself.
//
// The bug this covers came out of the user's own debug log: two writes overlapped
// and the second found its temp file already consumed by the first's rename, so
// one write was silently lost.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/utils/atomic_file.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('musync_atomic_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File target([String name = 'x.json']) =>
      File('${dir.path}${Platform.pathSeparator}$name');

  test('writes a file that was not there', () async {
    await AtomicFile.writeString(target(), 'bonjour');

    expect(await target().readAsString(), 'bonjour');
  });

  test('replaces the contents of one that was', () async {
    await target().writeAsString('avant');

    await AtomicFile.writeString(target(), 'après');

    expect(await target().readAsString(), 'après');
  });

  test('leaves no temp file behind', () async {
    await AtomicFile.writeString(target(), 'bonjour');

    final leftovers = dir
        .listSync()
        .map((e) => e.path)
        .where((p) => p.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('overlapping writes all complete, and the file is one of them', () async {
    // The reported failure: `PathNotFoundException: Cannot rename file to
    // '…/lyrics_status_cache.json', path = '…json.tmp'`. Two writers, one temp
    // name, and the loser's rename found nothing to rename.
    await Future.wait([
      for (var i = 0; i < 20; i++)
        AtomicFile.writeString(target(), 'valeur $i'),
    ]);

    // No exception is the assertion. And the contents are a whole write, never
    // a mixture of two.
    expect(await target().readAsString(), matches(RegExp(r'^valeur \d+$')));
  });

  test('overlapping writes to different files do not interfere', () async {
    await Future.wait([
      for (var i = 0; i < 10; i++)
        AtomicFile.writeString(target('f$i.json'), 'contenu $i'),
    ]);

    for (var i = 0; i < 10; i++) {
      expect(await target('f$i.json').readAsString(), 'contenu $i');
    }
  });

  test('bytes go through the same door', () async {
    await AtomicFile.writeBytes(target('b.bin'), [1, 2, 3, 250]);

    expect(await target('b.bin').readAsBytes(), [1, 2, 3, 250]);
  });

  test('creates a missing parent rather than failing', () async {
    // App data and cache directories can be cleared under a running process,
    // which is exactly how the artwork cache started failing every write.
    final nested = File(
      '${dir.path}${Platform.pathSeparator}gone'
      '${Platform.pathSeparator}deep.json',
    );

    await AtomicFile.writeString(nested, 'recréé');

    expect(await nested.readAsString(), 'recréé');
  });

  test('a failed write leaves the previous contents alone', () async {
    await target().writeAsString('intact');

    // A directory where the temp file needs to be is a write that cannot land.
    await Directory('${target().path}.tmp').create();

    await expectLater(
      AtomicFile.writeString(target(), 'jamais'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await target().readAsString(), 'intact');
  });
}
