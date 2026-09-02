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
import 'package:musync/features/sync_editor/data/timestamp_input.dart';
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
      await Id3Writer.writeLyrics(
        file.path,
        synced: synced,
        unsynced: unsynced,
      );
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
      // Untimed, not "timed at zero". The two say different things, and only
      // the first is true of a lyric nobody has stamped yet — pinning them all
      // at 00:00.00 would have written three SYLT entries at the very start of
      // the song the moment the user hit save.
      expect(editor.state.lines.map((l) => l.timestamp), everyElement(isNull));
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

      expect(editor.state.lines.map((l) => l.timestamp!.inSeconds), [
        5,
        10,
        15,
      ]);
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
      expect(editor.state.lines.map((l) => l.timestamp!.inMilliseconds), [
        10200,
        20200,
      ]);
    });

    test('the readout nets out to zero when the shift is undone', () {
      editor.offsetAll(const Duration(milliseconds: 100));
      editor.offsetAll(const Duration(milliseconds: -100));

      expect(editor.state.globalOffset, Duration.zero);
    });

    test('nudgeLine moves one line only', () {
      editor.nudgeLine(1, const Duration(milliseconds: -500));

      expect(editor.state.lines.map((l) => l.timestamp!.inMilliseconds), [
        10000,
        19500,
      ]);
      expect(editor.state.globalOffset, Duration.zero);
    });

    test('timestamps never go negative', () {
      editor.offsetAll(const Duration(seconds: -60));

      expect(
        editor.state.lines.map((l) => l.timestamp),
        everyElement(Duration.zero),
      );
    });

    test('resetTimings clears the clock but keeps the words', () {
      editor.resetTimings();

      expect(editor.state.lines.map((l) => l.text), ['Une', 'Deux']);
      // Un-timed, not timed-at-zero. This test used to assert `Duration.zero`
      // and so pinned the bug in place: every line read `00:00.00`, which claims
      // the whole song is sung at the first instant.
      expect(editor.state.lines.map((l) => l.timestamp), everyElement(isNull));
      expect(editor.state.lines.map((l) => l.isTimed), everyElement(isFalse));
      expect(editor.state.cursor, 0);
    });

    test('resetTimings leaves nothing behind to write into SYLT', () {
      // What the user sees is `--:--.--`; what reaches the file has to agree.
      editor.resetTimings();

      expect(editor.state.asSyncedLyrics.isEmpty, isTrue);
    });

    test('resetTimings also clears the global offset readout', () {
      // The two reset buttons sit close together, and T24 asks explicitly that
      // they not be confused. Wiping the timings makes any accumulated offset
      // meaningless, so the number must not survive to describe nothing.
      editor.offsetAll(const Duration(milliseconds: 500));
      editor.resetTimings();

      expect(editor.state.globalOffset, Duration.zero);
    });

    test('resetOffset does not touch the timestamps it has already undone', () {
      // The other half of that distinction: this button moves times, it does not
      // erase them.
      editor.offsetAll(const Duration(milliseconds: 500));
      editor.resetOffset();

      expect(editor.state.lines.map((l) => l.isTimed), everyElement(isTrue));
    });

    test('nudgeFrom the first line carries the whole song', () {
      editor.nudgeFrom(0, const Duration(milliseconds: 250));

      expect(editor.state.lines.map((l) => l.timestamp!.inMilliseconds), [
        10250,
        20250,
      ]);
      // Shifting from the top *is* a global offset, so the readout says so.
      expect(editor.state.globalOffset, const Duration(milliseconds: 250));
    });

    test('nudgeFrom further down leaves the lines above alone', () {
      editor.nudgeFrom(1, const Duration(milliseconds: 250));

      expect(editor.state.lines.map((l) => l.timestamp!.inMilliseconds), [
        10000,
        20250,
      ]);
      // A partial shift is not a global one; claiming otherwise in the readout
      // would misdescribe what was applied.
      expect(editor.state.globalOffset, Duration.zero);
    });

    test('resetOffset puts the timings back where they started', () {
      editor.offsetAll(const Duration(milliseconds: 700));
      editor.offsetAll(const Duration(milliseconds: 300));
      editor.resetOffset();

      expect(editor.state.lines.map((l) => l.timestamp!.inMilliseconds), [
        10000,
        20000,
      ]);
      expect(editor.state.globalOffset, Duration.zero);
    });

    test('resetLineTiming un-times one line and parks the cursor on it', () {
      editor.resetLineTiming(1);

      // Same correction as resetTimings: "je me suis trompé sur cette ligne"
      // must not leave it claiming to be sung at 00:00.00.
      expect(editor.state.lines[1].timestamp, isNull);
      expect(
        editor.state.lines[0].timestamp,
        const Duration(seconds: 10),
        reason: 'la ligne au-dessus ne bouge pas',
      );
      expect(editor.state.cursor, 1, reason: 'prete a etre recalee');
    });

    test('clearTimestamp strips the time and keeps the words', () {
      editor.clearTimestamp(0);

      expect(editor.state.lines[0].timestamp, isNull);
      expect(editor.state.lines[0].text, 'Une');

      // Still in the plain text that goes to USLT — and bare, while the line
      // that kept its time carries an LRC prefix. That mix is the point: the
      // marker survives in the words for a reader, without offering a
      // synchronised player a second to show it at.
      final plain = editor.state.asUnsyncedLyrics.text.split('\n');
      expect(plain.first, 'Une');
      expect(plain.last, matches(r'^\[\d{2}:\d{2}\.\d{2}\]Deux$'));

      // ...and no longer one of the timed lines that become SYLT.
      expect(editor.state.asSyncedLyrics.lines.map((l) => l.text), ['Deux']);
    });

    test('alignAllFrom shifts everything by the drift it measures', () {
      // Line 0 is written at 10 s but is actually heard at 12.5 s.
      final delta = editor.alignAllFrom(0, const Duration(milliseconds: 12500));

      expect(delta, const Duration(milliseconds: 2500));
      expect(editor.state.lines.map((l) => l.timestamp!.inMilliseconds), [
        12500,
        22500,
      ]);
      // The spacing between lines is the part that was already correct — it is
      // exactly what a global shift has to leave alone.
      expect(
        editor.state.lines[1].timestamp! - editor.state.lines[0].timestamp!,
        const Duration(seconds: 10),
      );
    });

    test('alignAllFrom on an untimed line only stamps that line', () {
      editor.clearTimestamp(0);

      final delta = editor.alignAllFrom(0, const Duration(seconds: 30));

      expect(delta, isNull, reason: 'aucune dérive mesurable');
      expect(editor.state.lines[0].timestamp, const Duration(seconds: 30));
      // No drift could be inferred, so the rest must not have moved.
      expect(editor.state.lines[1].timestamp, const Duration(seconds: 20));
    });

    test('shifting never hands an untimed line a time back', () {
      editor.clearTimestamp(0);
      editor.offsetAll(const Duration(seconds: 5));
      editor.nudgeFrom(0, const Duration(seconds: 5));
      editor.nudgeLine(0, const Duration(seconds: 5));

      expect(
        editor.state.lines[0].timestamp,
        isNull,
        reason: 'effacer un horodatage est une decision, pas un zero',
      );
      expect(editor.state.lines[1].timestamp, const Duration(seconds: 30));
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

      expect(editor.state.lines.map((l) => l.timestamp), [
        const Duration(seconds: 10),
        const Duration(seconds: 20),
        // The new line arrives *untimed*. This asserted `0` and so pinned the
        // wrong behaviour: `00:00.00` says the line is sung at the very first
        // instant, and it would have gone into SYLT saying so.
        isNull,
      ]);
      expect(editor.state.lines.map((l) => l.text), ['Une', 'Deux', 'Trois']);
    });

    test('a pasted line beyond the old count stays out of SYLT', () {
      editor.replaceAllText('Une\nDeux\nTrois');

      // Two timed lines, not three: the untimed one keeps its words in the plain
      // frame and contributes nothing to the timings.
      expect(editor.state.asSyncedLyrics.length, 2);
      expect(editor.state.asUnsyncedLyrics.text, contains('Trois'));
    });

    test('a line inserted with nothing above it is untimed', () {
      // Same correction: there is no timestamp to inherit, so it must not
      // invent one.
      editor.insertLineAfter(-1);

      expect(editor.state.lines.first.timestamp, isNull);
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
      final song = await makeSong(unsynced: const UnsyncedLyrics('Une\nDeux'));
      final editor = await openEditor(song);

      editor.stampCursorAt(const Duration(seconds: 3));
      editor.stampCursorAt(const Duration(seconds: 6));

      await Id3Writer.writeLyrics(
        song.filePath,
        synced: editor.state.asSyncedLyrics,
        unsynced: editor.state.asUnsyncedLyrics,
      );

      final reopened = await openEditor(song);
      expect(reopened.state.lines.map((l) => l.timestamp!.inSeconds), [3, 6]);
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
      expect(editor.state.asSyncedLyrics.lines.map((l) => l.text), [
        'Deux',
        'Trois',
        'Une',
      ]);
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
      expect(
        [a].indexOf(b),
        0,
        reason: 'the player queue looks songs up this way',
      );
    });
  });

  group('fixtures sanity', () {
    test('the temp MP3 helper really produces readable lyrics', () async {
      final song = await makeSong(
        unsynced: const UnsyncedLyrics('Accents éàü'),
      );
      final bytes = await File(song.filePath).readAsBytes();

      expect(utf8.decode(bytes.sublist(0, 3)), 'ID3');
    });
  });

  group('the typed timestamp field', () {
    test('reads the shapes people actually type', () {
      expect(
        TimestampInput.parse('1:23'),
        const Duration(minutes: 1, seconds: 23),
      );
      expect(
        TimestampInput.parse('01:23.45'),
        const Duration(minutes: 1, seconds: 23, milliseconds: 450),
      );
      // Seconds past 59 are allowed on purpose: `83` means 1:23.
      expect(TimestampInput.parse('83'), const Duration(seconds: 83));
      expect(
        TimestampInput.parse('1,5'),
        const Duration(seconds: 1, milliseconds: 500),
      );
    });

    test('a fraction is padded, not truncated', () {
      // ".4" is four tenths and ".45" forty-five hundredths. Parsing them raw
      // would make both a handful of milliseconds.
      expect(TimestampInput.parse('0.4')!.inMilliseconds, 400);
      expect(TimestampInput.parse('0.45')!.inMilliseconds, 450);
      expect(TimestampInput.parse('0.456')!.inMilliseconds, 456);
    });

    test('rubbish is refused, not guessed at', () {
      expect(TimestampInput.parse(''), isNull);
      expect(TimestampInput.parse('   '), isNull);
      expect(TimestampInput.parse('abc'), isNull);
      expect(TimestampInput.parse('1:2:3'), isNull);
      expect(TimestampInput.parse('-5'), isNull);
    });

    test('a number too large to hold is refused rather than fatal', () {
      // The seconds group has no ceiling, and `int.parse` answers an overlong
      // run of digits with an exception — thrown out of a text field, where
      // nothing was waiting to catch it. A hand resting on a key is a rejected
      // entry, not a crash.
      final tooLong = '9' * 30;
      expect(() => TimestampInput.parse(tooLong), returnsNormally);
      expect(TimestampInput.parse(tooLong), isNull);
      expect(TimestampInput.parse('$tooLong:12'), isNull);
    });
  });
}
