// The swap that puts an edited working copy over a user's audio file: the
// target gets the new bytes, and no temp file — the cache copy or the
// sibling next to the target — survives, success or failure.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/utils/audio_file_replace.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('musync_replace_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('replaces the target and removes both temp files', () async {
    final target = File('${dir.path}/song.mp3')..writeAsBytesSync([1, 2, 3]);
    final work = File('${dir.path}/work.tmp')..writeAsBytesSync([9, 9]);

    await AudioFileReplace.commit(work, target);

    expect(target.readAsBytesSync(), [9, 9]);
    expect(work.existsSync(), isFalse);
    expect(
      File('${target.path}${AudioFileReplace.stageSuffix}').existsSync(),
      isFalse,
    );
  });

  test('a failure leaves the target untouched and no temp behind', () async {
    final target = File('${dir.path}/song.mp3')..writeAsBytesSync([1, 2, 3]);
    // A working copy that does not exist: the copy step throws.
    final work = File('${dir.path}/missing.tmp');

    await expectLater(
      AudioFileReplace.commit(work, target),
      throwsA(isA<FileSystemException>()),
    );

    expect(target.readAsBytesSync(), [1, 2, 3]);
    expect(
      File('${target.path}${AudioFileReplace.stageSuffix}').existsSync(),
      isFalse,
    );
  });

  test('a stale sibling from a killed run is replaced, not kept', () async {
    final target = File('${dir.path}/song.mp3')..writeAsBytesSync([1]);
    File('${target.path}${AudioFileReplace.stageSuffix}')
        .writeAsBytesSync([7, 7, 7]);
    final work = File('${dir.path}/work.tmp')..writeAsBytesSync([2]);

    await AudioFileReplace.commit(work, target);

    expect(target.readAsBytesSync(), [2]);
    expect(
      File('${target.path}${AudioFileReplace.stageSuffix}').existsSync(),
      isFalse,
    );
  });
}
