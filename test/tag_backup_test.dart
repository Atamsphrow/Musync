// Undoing a write.
//
// This module exists to put a user's music back the way it was, so the bar is
// the same as for the writer itself: the audio must come through untouched, and
// a restore must never make things worse than not restoring at all.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/id3/tag_backup.dart';

/// A tag built by hand, so a bug shared with `Id3Tag.build` cannot hide behind
/// a round trip.
Uint8List _tagBytes({int major = 4, int payload = 200}) {
  final body = BytesBuilder()
    ..add(ascii.encode('APIC'))
    ..add(
      major == 4
          ? [
              (payload >> 21) & 0x7F,
              (payload >> 14) & 0x7F,
              (payload >> 7) & 0x7F,
              payload & 0x7F,
            ]
          : [
              (payload >> 24) & 0xFF,
              (payload >> 16) & 0xFF,
              (payload >> 8) & 0xFF,
              payload & 0xFF,
            ],
    )
    ..add([0, 0])
    ..add(List<int>.generate(payload, (i) => (i + 3) % 256));

  final bodyBytes = body.toBytes();
  return (BytesBuilder()
        ..add(ascii.encode('ID3'))
        ..add([major, 0, 0])
        ..add([
          (bodyBytes.length >> 21) & 0x7F,
          (bodyBytes.length >> 14) & 0x7F,
          (bodyBytes.length >> 7) & 0x7F,
          bodyBytes.length & 0x7F,
        ])
        ..add(bodyBytes))
      .toBytes();
}

Uint8List _audio() =>
    Uint8List.fromList(List<int>.generate(8192, (i) => (i * 7) % 256));

void main() {
  late Directory tempDir;
  late TagBackupStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_backup_');
    store = TagBackupStore(root: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> makeTrack(String name, {int major = 4}) async {
    final path = '${tempDir.path}${Platform.pathSeparator}$name';
    await File(path).writeAsBytes([..._tagBytes(major: major), ..._audio()]);
    return path;
  }

  final lyrics = SyncedLyrics([
    const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
    const LyricLine(timestamp: Duration(seconds: 4), text: 'Deux'),
  ]);

  group('capture and restore', () {
    test('puts the file back byte for byte', () async {
      final path = await makeTrack('track.mp3');
      final before = await File(path).readAsBytes();

      await store.capture(path);
      await Id3Writer.writeLyrics(path, synced: lyrics);
      await store.markWritten(path);

      // The write really happened, or the restore below proves nothing.
      expect(
        Id3Reader.readLyricsFromBytes(await File(path).readAsBytes()).synced,
        isNotNull,
      );

      await store.restore(path);

      expect(await File(path).readAsBytes(), before);
    });

    test('leaves the audio untouched when the tag grew', () async {
      // The written tag is bigger than the original, so the audio moved. The
      // restore has to splice rather than overwrite in place — this is the case
      // that would corrupt a track if it got the offset wrong.
      final path = await makeTrack('grow.mp3');
      final audioBefore = _audio();
      final offsetBefore = Id3Tag.parse(
        await File(path).readAsBytes(),
      )!.audioOffset;

      await store.capture(path);
      await Id3Writer.writeLyrics(path, synced: lyrics);
      await store.markWritten(path);

      // The premise of the test, asserted rather than assumed: if the tag did
      // not actually grow, the splice below is never exercised.
      final offsetAfter = Id3Tag.parse(
        await File(path).readAsBytes(),
      )!.audioOffset;
      expect(offsetAfter, greaterThan(offsetBefore));

      await store.restore(path);

      final after = await File(path).readAsBytes();
      final tag = Id3Tag.parse(after)!;
      expect(Uint8List.sublistView(after, tag.audioOffset), audioBefore);
    });

    test('the lyrics really are the previous ones', () async {
      final path = await makeTrack('previous.mp3');
      await Id3Writer.writeLyrics(
        path,
        unsynced: const UnsyncedLyrics('Les paroles d’origine'),
      );

      await store.capture(path);
      await Id3Writer.writeLyrics(path, synced: lyrics);
      await store.markWritten(path);
      await store.restore(path);

      final read = Id3Reader.readLyricsFromBytes(
        await File(path).readAsBytes(),
      );
      expect(read.synced, isNull);
      expect(read.unsynced!.text, 'Les paroles d’origine');
    });

    test('a track that had no tag gets none back', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}bare.mp3';
      await File(path).writeAsBytes(_audio());

      await store.capture(path);
      await Id3Writer.writeLyrics(path, synced: lyrics);
      await store.markWritten(path);
      expect(Id3Tag.parse(await File(path).readAsBytes()), isNotNull);

      await store.restore(path);

      // Putting nothing back in front of the audio is exactly how it started.
      expect(Id3Tag.parse(await File(path).readAsBytes()), isNull);
      expect(await File(path).readAsBytes(), _audio());
    });

    test('a v2.3 tag comes back as v2.3', () async {
      final path = await makeTrack('v23.mp3', major: 3);

      await store.capture(path);
      await Id3Writer.writeLyrics(path, synced: lyrics);
      await store.markWritten(path);
      await store.restore(path);

      expect(Id3Tag.parse(await File(path).readAsBytes())!.majorVersion, 3);
    });
  });

  group('what it refuses', () {
    test('restoring without a backup', () async {
      final path = await makeTrack('none.mp3');
      expect(() => store.restore(path), throwsA(isA<TagRestoreException>()));
    });

    test('a file changed by something else since', () async {
      final path = await makeTrack('touched.mp3');
      await store.capture(path);
      await Id3Writer.writeLyrics(path, synced: lyrics);
      await store.markWritten(path);

      // Another tagger, later. Restoring blind would undo their work too.
      await Id3Writer.writeLyrics(
        path,
        unsynced: const UnsyncedLyrics('écrit par quelqu’un d’autre'),
      );
      await File(
        path,
      ).setLastModified(DateTime.now().add(const Duration(seconds: 5)));

      expect(() => store.restore(path), throwsA(isA<TagRestoreException>()));
    });

    test('unless it is forced', () async {
      final path = await makeTrack('forced.mp3');
      await store.capture(path);
      await Id3Writer.writeLyrics(path, synced: lyrics);
      await store.markWritten(path);
      await Id3Writer.writeLyrics(
        path,
        unsynced: const UnsyncedLyrics('autre chose'),
      );
      await File(
        path,
      ).setLastModified(DateTime.now().add(const Duration(seconds: 5)));

      await store.restore(path, force: true);

      expect(
        Id3Reader.readLyricsFromBytes(await File(path).readAsBytes()).unsynced,
        isNull,
      );
    });

    test('capturing a file that is not there', () async {
      // Reported, not thrown: a backup that cannot be taken must not stop the
      // user embedding lyrics.
      expect(await store.capture('${tempDir.path}/absent.mp3'), isFalse);
    });
  });

  group('the index', () {
    test('keeps one entry per track, the most recent', () async {
      final path = await makeTrack('twice.mp3');

      await store.capture(path);
      await Id3Writer.writeLyrics(path, synced: lyrics);
      await store.capture(path);

      expect(await store.list(), hasLength(1));
    });

    test('a restore consumes the backup', () async {
      final path = await makeTrack('consumed.mp3');
      await store.capture(path);
      await Id3Writer.writeLyrics(path, synced: lyrics);
      await store.markWritten(path);

      await store.restore(path);

      // There is nothing left to undo, and the list must say so.
      expect(await store.backupFor(path), isNull);
      expect(await store.list(), isEmpty);
    });

    test('several tracks each keep their own', () async {
      final a = await makeTrack('a.mp3');
      final b = await makeTrack('b.mp3');
      await store.capture(a);
      await store.capture(b);

      final entries = await store.list();
      expect(entries, hasLength(2));
      expect(entries.map((e) => e.filePath), containsAll([a, b]));
    });

    test('clear removes the entries and their bytes', () async {
      await store.capture(await makeTrack('gone.mp3'));
      await store.clear();

      expect(await store.list(), isEmpty);
      final leftovers = Directory(
        '${tempDir.path}${Platform.pathSeparator}tag_backups',
      ).listSync().where((e) => e.path.endsWith('.tag'));
      expect(leftovers, isEmpty);
    });

    test('survives an unreadable index rather than throwing', () async {
      await store.capture(await makeTrack('ok.mp3'));
      await File(
        '${tempDir.path}${Platform.pathSeparator}tag_backups'
        '${Platform.pathSeparator}index.json',
      ).writeAsString('{ pas du json');

      // A corrupt index costs the history, not the app.
      expect(await store.list(), isEmpty);
    });
  });
}
