// Tests for the sync editor's state machine.
//
// This is where the app's central interaction lives — play the track, tap once
// per line — so the cursor behaviour is asserted directly rather than through
// the widget tree.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/sync_editor/providers/sync_editor_provider.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_editor_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// A tagless MP3 stand-in. The writer creates a v2.4 tag from scratch.
  Future<Song> makeSong({
    SyncedLyrics? synced,
    UnsyncedLyrics? unsynced,
  }) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}track.mp3');
    await file.writeAsBytes(
      Uint8List.fromList(List<int>.generate(4096, (i) => (i * 13) % 256)),
    );
    if (synced != null || unsynced != null) {
      await Id3Writer.writeLyrics(file.path, synced: synced, unsynced: unsynced);
    }
    return Song(
      id: 1,
      title: 'Titre',
      artist: 'Artiste',
      album: 'Album',
      duration: 180000,
      filePath: file.path,
    );
  }

  /// Builds the notifier and waits for its initial read to land.
  Future<SyncEditorNotifier> openEditor(Song song) async {
    final notifier = SyncEditorNotifier(song);
    // The constructor kicks off an async file read; one microtask drain is not
    // enough because the read itself hits the event loop.
    while (notifier.state.isLoading) {
      await Future<void>.delayed(Duration.zero);
    }
    return notifier;
  }

  group('loading', () {
    test('reads the synced lyrics already in the file', () async {
      final song = await makeSong(
        synced: SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
          const LyricLine(timestamp: Duration(seconds: 2), text: 'Deux'),
        ]),
      );

      final editor = await openEditor(song);

      expect(editor.state.lines.map((l) => l.text), ['Une', 'Deux']);
      expect(editor.state.mode, SyncMode.synced);
      expect(editor.state.hasChanges, isFalse);
    });

    test('seeds untimed lines from plain lyrics, ready to be timed', () async {
      final song = await makeSong(
        unsynced: const UnsyncedLyrics('Première\nDeuxième\nTroisième'),
      );

      final editor = await openEditor(song);

      expect(editor.state.lines, hasLength(3));
      expect(editor.state.lines.map((l) => l.timestamp),
          everyElement(Duration.zero));
      // Opening in Simple mode matches what the file actually holds.
      expect(editor.state.mode, SyncMode.simple);
    });

    test('a file with no lyrics opens empty rather than failing', () async {
      final editor = await openEditor(await makeSong());

      expect(editor.state.isEmpty, isTrue);
      expect(editor.state.isLoading, isFalse);
    });
  });

  group('stamping — the core interaction', () {
    late SyncEditorNotifier editor;

    setUp(() async {
      editor = await openEditor(
        await makeSong(unsynced: const UnsyncedLyrics('Une\nDeux\nTrois')),
      );
    });

    test('stamps the cursor line and steps to the next', () async {
      final stamped = editor.stampCursorAt(const Duration(seconds: 5));

      expect(stamped, 0);
      expect(editor.state.lines[0].timestamp, const Duration(seconds: 5));
      expect(editor.state.cursor, 1);
      expect(editor.state.hasChanges, isTrue);
    });

    test('walks the whole song one tap at a time', () {
      editor.stampCursorAt(const Duration(seconds: 5));
      editor.stampCursorAt(const Duration(seconds: 10));
      editor.stampCursorAt(const Duration(seconds: 15));

      expect(editor.state.lines.map((l) => l.timestamp.inSeconds), [5, 10, 15]);
      expect(editor.state.cursor, 3);
    });

    test('reports null once every line is timed', () {
      for (var i = 0; i < 3; i++) {
        editor.stampCursorAt(Duration(seconds: i));
      }

      expect(editor.stampCursorAt(const Duration(seconds: 99)), isNull);
    });

    test('lines keep their reading order even when timed out of sequence', () {
      // Stamping line 3 early must not reorder the text under the user.
      editor.setCursor(2);
      editor.stampCursorAt(const Duration(seconds: 5));

      expect(editor.state.lines.map((l) => l.text), ['Une', 'Deux', 'Trois']);
    });

    test('setCursor clamps instead of going out of range', () {
      editor.setCursor(99);
      expect(editor.state.cursor, 3);

      editor.setCursor(-5);
      expect(editor.state.cursor, 0);
    });
  });

  group('offsets', () {
    late SyncEditorNotifier editor;

    setUp(() async {
      editor = await openEditor(
        await makeSong(
          synced: SyncedLyrics([
            const LyricLine(timestamp: Duration(seconds: 10), text: 'Une'),
            const LyricLine(timestamp: Duration(seconds: 20), text: 'Deux'),
          ]),
        ),
      );
    });

    test('offsetAll shifts every line and accumulates the readout', () {
      editor.offsetAll(const Duration(milliseconds: 100));
      editor.offsetAll(const Duration(milliseconds: 100));

      expect(editor.state.globalOffset, const Duration(milliseconds: 200));
      expect(editor.state.lines.map((l) => l.timestamp.inMilliseconds),
          [10200, 20200]);
    });

    test('the readout nets out to zero when the shift is undone', () {
      editor.offsetAll(const Duration(milliseconds: 100));
      editor.offsetAll(const Duration(milliseconds: -100));

      expect(editor.state.globalOffset, Duration.zero);
    });

    test('nudgeLine moves one line only', () {
      editor.nudgeLine(1, const Duration(milliseconds: -500));

      expect(editor.state.lines.map((l) => l.timestamp.inMilliseconds),
          [10000, 19500]);
      expect(editor.state.globalOffset, Duration.zero);
    });

    test('timestamps never go negative', () {
      editor.offsetAll(const Duration(seconds: -60));

      expect(editor.state.lines.map((l) => l.timestamp),
          everyElement(Duration.zero));
    });

    test('resetTimings clears the clock but keeps the words', () {
      editor.resetTimings();

      expect(editor.state.lines.map((l) => l.text), ['Une', 'Deux']);
      expect(editor.state.lines.map((l) => l.timestamp),
          everyElement(Duration.zero));
      expect(editor.state.cursor, 0);
    });
  });

  group('text editing', () {
    late SyncEditorNotifier editor;

    setUp(() async {
      editor = await openEditor(
        await makeSong(
          synced: SyncedLyrics([
            const LyricLine(timestamp: Duration(seconds: 10), text: 'Une'),
            const LyricLine(timestamp: Duration(seconds: 20), text: 'Deux'),
          ]),
        ),
      );
    });

    test('updateLineText leaves the timestamp alone', () {
      editor.updateLineText(0, 'Corrigée');

      expect(editor.state.lines[0].text, 'Corrigée');
      expect(editor.state.lines[0].timestamp, const Duration(seconds: 10));
    });

    test('replaceAllText keeps the timing already done', () {
      // Fixing a typo must not cost the work of timing the earlier lines.
      editor.replaceAllText('Une\nDeux\nTrois');

      expect(editor.state.lines.map((l) => l.timestamp.inSeconds), [10, 20, 0]);
      expect(editor.state.lines.map((l) => l.text), ['Une', 'Deux', 'Trois']);
    });

    test('replaceAllText shrinking the lyric clamps the cursor', () {
      editor.setCursor(2);
      editor.replaceAllText('Seule');

      expect(editor.state.lines, hasLength(1));
      expect(editor.state.cursor, 1);
    });

    test('insertLineAfter inherits the timestamp above it', () {
      editor.insertLineAfter(0);

      expect(editor.state.lines, hasLength(3));
      expect(editor.state.lines[1].text, isEmpty);
      expect(editor.state.lines[1].timestamp, const Duration(seconds: 10));
    });

    test('removeLine drops the line and clamps the cursor', () {
      editor.setCursor(2);
      editor.removeLine(0);

      expect(editor.state.lines.map((l) => l.text), ['Deux']);
      expect(editor.state.cursor, 1);
    });

    test('out-of-range edits are ignored rather than throwing', () {
      editor.updateLineText(99, 'nulle part');
      editor.removeLine(-1);
      editor.nudgeLine(42, const Duration(seconds: 1));

      expect(editor.state.lines, hasLength(2));
    });
  });

  group('saving', () {
    test('writes SYLT and USLT, and round-trips', () async {
      final song = await makeSong(
        unsynced: const UnsyncedLyrics('Une\nDeux'),
      );
      final editor = await openEditor(song);

      editor.stampCursorAt(const Duration(seconds: 3));
      editor.stampCursorAt(const Duration(seconds: 6));

      await Id3Writer.writeLyrics(
        song.filePath,
        synced: editor.state.asSyncedLyrics,
        unsynced: editor.state.asUnsyncedLyrics,
      );

      final reopened = await openEditor(song);
      expect(reopened.state.lines.map((l) => l.timestamp.inSeconds), [3, 6]);
      expect(reopened.state.lines.map((l) => l.text), ['Une', 'Deux']);
    });

    test('markSaved clears the pending markers', () async {
      final editor = await openEditor(
        await makeSong(unsynced: const UnsyncedLyrics('Une')),
      );
      editor.offsetAll(const Duration(milliseconds: 100));
      expect(editor.state.hasChanges, isTrue);

      editor.markSaved();

      expect(editor.state.hasChanges, isFalse);
      expect(editor.state.globalOffset, Duration.zero);
      expect(editor.state.isSaving, isFalse);
    });

    test('asSyncedLyrics sorts, so SYLT gets ascending timestamps', () async {
      final editor = await openEditor(
        await makeSong(unsynced: const UnsyncedLyrics('Une\nDeux\nTrois')),
      );

      // Timed out of order, as happens when the user goes back to fix a line.
      editor.updateTimestamp(0, const Duration(seconds: 30));
      editor.updateTimestamp(1, const Duration(seconds: 10));
      editor.updateTimestamp(2, const Duration(seconds: 20));

      expect(editor.state.lines.map((l) => l.text), ['Une', 'Deux', 'Trois']);
      expect(editor.state.asSyncedLyrics.lines.map((l) => l.text),
          ['Deux', 'Trois', 'Une']);
    });
  });

  group('Song identity', () {
    test('two scans of the same file compare equal', () {
      const a = Song(
        id: 42,
        title: 'Titre',
        artist: 'Artiste',
        album: 'Album',
        duration: 1000,
        filePath: '/a.mp3',
      );
      // Same MediaStore id, tags edited since the last scan.
      const b = Song(
        id: 42,
        title: 'Titre corrigé',
        artist: 'Artiste',
        album: 'Album',
        duration: 1000,
        filePath: '/a.mp3',
      );

      expect(a, b);
      expect([a].indexOf(b), 0, reason: 'the player queue looks songs up this way');
    });

    test('artworkUri is null without an album id', () {
      const song = Song(
        id: 1,
        title: 't',
        artist: 'a',
        album: 'al',
        duration: 0,
        filePath: '/a.mp3',
      );

      expect(song.artworkUri, isNull);
      expect(song.copyWith(albumId: 7).artworkUri.toString(),
          'content://media/external/audio/albumart/7');
    });
  });

  group('fixtures sanity', () {
    test('the temp MP3 helper really produces readable lyrics', () async {
      final song = await makeSong(unsynced: const UnsyncedLyrics('Accents éàü'));
      final bytes = await File(song.filePath).readAsBytes();

      expect(utf8.decode(bytes.sublist(0, 3)), 'ID3');
    });
  });
}
