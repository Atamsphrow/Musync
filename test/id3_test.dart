// Tests for the hand-rolled ID3v2 reader/writer.
//
// This is the riskiest code in Musync: it rewrites the user's own music files,
// and a mistake here costs artwork or metadata that can't be recovered. The
// fixtures below are assembled byte by byte rather than through Id3Tag.build,
// so a bug shared by the writer and the parser can't hide behind a round trip.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';

class _Frame {
  final String id;
  final List<int> body;
  const _Frame(this.id, this.body);
}

/// Assembles a tag the way a real tagger would: v2.3 frame sizes big-endian,
/// v2.4 frame sizes synchsafe, tag header size synchsafe in both.
Uint8List _tagBytes({
  required int major,
  required List<_Frame> frames,
  int padding = 0,
  int headerFlags = 0,
}) {
  final body = BytesBuilder();
  for (final frame in frames) {
    final size = frame.body.length;
    body.add(ascii.encode(frame.id));
    body.add(major == 4
        ? [
            (size >> 21) & 0x7F,
            (size >> 14) & 0x7F,
            (size >> 7) & 0x7F,
            size & 0x7F,
          ]
        : [
            (size >> 24) & 0xFF,
            (size >> 16) & 0xFF,
            (size >> 8) & 0xFF,
            size & 0xFF,
          ]);
    body.add([0, 0]); // frame flags
    body.add(frame.body);
  }
  body.add(List<int>.filled(padding, 0));
  final bodyBytes = body.toBytes();

  return (BytesBuilder()
        ..add(ascii.encode('ID3'))
        ..add([major, 0, headerFlags])
        ..add([
          (bodyBytes.length >> 21) & 0x7F,
          (bodyBytes.length >> 14) & 0x7F,
          (bodyBytes.length >> 7) & 0x7F,
          bodyBytes.length & 0x7F,
        ])
        ..add(bodyBytes))
      .toBytes();
}

/// Stand-in for the MP3 stream. Deliberately long enough that a full rewrite
/// moving it would be obvious.
Uint8List _audio() =>
    Uint8List.fromList(List<int>.generate(8192, (i) => (i * 7) % 256));

/// A frame big enough that big-endian and synchsafe sizes disagree — 200 reads
/// back as 72 if a v2.3 size is parsed as synchsafe. Cover art is always this
/// side of the line, which is why mixing the two encodings destroys it.
_Frame _artworkFrame() =>
    _Frame('APIC', List<int>.generate(200, (i) => (i + 3) % 256));

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_id3_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<File> writeFixture(String name, List<int> bytes) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  group('Id3Tag.parse', () {
    test('reads v2.3 frames, whose sizes are big-endian', () {
      final bytes = _tagBytes(
        major: 3,
        frames: [_artworkFrame(), const _Frame('TIT2', [0, 65, 66])],
      );

      final tag = Id3Tag.parse(bytes)!;

      expect(tag.majorVersion, 3);
      expect(tag.isSupported, isTrue);
      expect(tag.frames.map((f) => f.id), ['APIC', 'TIT2']);
      expect(tag.frameById('APIC')!.body, hasLength(200));
    });

    test('reads v2.4 frames, whose sizes are synchsafe', () {
      final bytes = _tagBytes(major: 4, frames: [_artworkFrame()]);

      final tag = Id3Tag.parse(bytes)!;

      expect(tag.majorVersion, 4);
      expect(tag.frameById('APIC')!.body, hasLength(200));
    });

    test('returns null when there is no tag', () {
      expect(Id3Tag.parse(_audio()), isNull);
    });

    test('flags v2.2 as unsupported instead of misreading it', () {
      // v2.2 uses 3-character frame IDs, so the v2.3+ walker would desync.
      final bytes = _tagBytes(major: 2, frames: const []);

      final tag = Id3Tag.parse(bytes)!;

      expect(tag.isSupported, isFalse);
    });

    test('stops at padding rather than reading it as frames', () {
      final bytes = _tagBytes(
        major: 4,
        frames: [const _Frame('TIT2', [0, 65])],
        padding: 512,
      );

      expect(Id3Tag.parse(bytes)!.frames, hasLength(1));
    });

    test('skips the footer when locating the audio', () {
      final bytes = _tagBytes(
        major: 4,
        frames: [const _Frame('TIT2', [0, 65])],
        headerFlags: 0x10, // footer present
      );

      // 10 header + body + 10 footer.
      expect(Id3Tag.parse(bytes)!.audioOffset, bytes.length + 10);
    });

    test('undoes whole-tag unsynchronisation', () {
      // $FF $00 is how an unsynchronised tag hides a byte that would otherwise
      // look like an MPEG frame sync.
      final bytes = _tagBytes(
        major: 3,
        frames: const [
          _Frame('TIT2', [0, 0xFF, 0x00, 0x41])
        ],
        headerFlags: 0x80,
      );

      final tag = Id3Tag.parse(bytes)!;

      expect(tag.frameById('TIT2')!.body, [0, 0xFF, 0x41]);
    });
  });

  group('writeLyrics preserves the rest of the file', () {
    test('leaves a v2.3 artwork frame byte-identical and keeps the version', () async {
      // The regression this whole module was rewritten for: the old writer
      // copied v2.3 frames verbatim under a v2.4 header, so every frame over
      // 127 bytes became unreadable.
      final artwork = _artworkFrame();
      final audio = _audio();
      final file = await writeFixture('v23.mp3', [
        ..._tagBytes(major: 3, frames: [artwork]),
        ...audio,
      ]);

      await Id3Writer.writeLyrics(
        file.path,
        synced: SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'Bonjour'),
        ]),
      );

      final tag = Id3Tag.parse(await file.readAsBytes())!;
      expect(tag.majorVersion, 3, reason: 'the tag version must not change');
      expect(tag.frameById('APIC')!.body, artwork.body);
    });

    test('leaves the audio stream untouched', () async {
      final audio = _audio();
      final file = await writeFixture('audio.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ...audio,
      ]);

      await Id3Writer.writeLyrics(
        file.path,
        unsynced: const UnsyncedLyrics('paroles'),
      );

      final bytes = await file.readAsBytes();
      final tag = Id3Tag.parse(bytes)!;
      expect(Uint8List.sublistView(bytes, tag.audioOffset), audio);
    });

    test('writes a tag into a file that had none', () async {
      final audio = _audio();
      final file = await writeFixture('bare.mp3', audio);

      await Id3Writer.writeLyrics(
        file.path,
        unsynced: const UnsyncedLyrics('paroles'),
      );

      final bytes = await file.readAsBytes();
      final tag = Id3Tag.parse(bytes)!;
      expect(tag.majorVersion, 4, reason: 'new tags should be v2.4');
      expect(Uint8List.sublistView(bytes, tag.audioOffset), audio);
    });

    test('refuses to rewrite a v2.2 tag rather than mangle it', () async {
      final file = await writeFixture('v22.mp3', [
        ..._tagBytes(major: 2, frames: const []),
        ..._audio(),
      ]);

      expect(
        () => Id3Writer.writeLyrics(
          file.path,
          unsynced: const UnsyncedLyrics('paroles'),
        ),
        throwsA(isA<Id3WriteException>()),
      );
    });

    test('reuses the existing tag space when the new tag fits', () async {
      final file = await writeFixture('padded.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()], padding: 4096),
        ..._audio(),
      ]);
      final sizeBefore = await file.length();

      await Id3Writer.writeLyrics(
        file.path,
        synced: SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'court'),
        ]),
      );

      // Same length means the audio was never moved — the fast path taken.
      expect(await file.length(), sizeBefore);
    });

    test('grows the file when the new tag does not fit', () async {
      final file = await writeFixture('tight.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);

      final lyrics = SyncedLyrics([
        for (var i = 0; i < 200; i++)
          LyricLine(
            timestamp: Duration(seconds: i),
            text: 'Une ligne de paroles assez longue numéro $i',
          ),
      ]);
      await Id3Writer.writeLyrics(file.path, synced: lyrics);

      expect(Id3Reader.readLyricsFromBytes(await file.readAsBytes()).synced!.lines,
          hasLength(200));
    });

    test('leaves no temp file behind', () async {
      final file = await writeFixture('clean.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);

      await Id3Writer.writeLyrics(
        file.path,
        unsynced: const UnsyncedLyrics('paroles'),
      );

      final leftovers = tempDir
          .listSync()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
      expect(file.existsSync(), isTrue);
    });
  });

  group('lyrics round trip', () {
    /// Runs a write-then-read cycle against a tag of the given version.
    Future<LyricsPair> roundTrip(
      int major, {
      SyncedLyrics? synced,
      UnsyncedLyrics? unsynced,
    }) async {
      final file = await writeFixture('rt$major.mp3', [
        ..._tagBytes(major: major, frames: [_artworkFrame()]),
        ..._audio(),
      ]);
      await Id3Writer.writeLyrics(file.path, synced: synced, unsynced: unsynced);
      return Id3Reader.readLyricsFromBytes(await file.readAsBytes());
    }

    final sample = SyncedLyrics([
      const LyricLine(timestamp: Duration.zero, text: 'Première ligne'),
      const LyricLine(
        timestamp: Duration(seconds: 12, milliseconds: 340),
        text: 'Deuxième — avec des accents éàü',
      ),
      const LyricLine(
        timestamp: Duration(minutes: 3, seconds: 7),
        text: 'Troisième',
      ),
    ]);

    test('SYLT survives a v2.4 round trip (UTF-8)', () async {
      final result = await roundTrip(4, synced: sample);
      expect(result.synced!.lines, sample.lines);
    });

    test('SYLT survives a v2.3 round trip (UTF-16)', () async {
      // v2.3 predates UTF-8 in ID3, so the writer has to fall back to UTF-16
      // and the reader has to follow the BOM back.
      final result = await roundTrip(3, synced: sample);
      expect(result.synced!.lines, sample.lines);
    });

    test('USLT survives a round trip with non-ASCII text', () async {
      const text = 'Une chanson\nen français\navec des accents : éàçüœ';
      final result = await roundTrip(4, unsynced: const UnsyncedLyrics(text));
      expect(result.unsynced!.text, text);
    });

    test('emoji survive UTF-16 surrogate pairs', () async {
      final result = await roundTrip(
        3,
        synced: SyncedLyrics([
          const LyricLine(timestamp: Duration.zero, text: 'Musique 🎵 forte'),
        ]),
      );
      expect(result.synced!.lines.first.text, 'Musique 🎵 forte');
    });

    test('both frames can coexist', () async {
      final result = await roundTrip(
        4,
        synced: sample,
        unsynced: const UnsyncedLyrics('texte simple'),
      );
      expect(result.synced!.lines, hasLength(3));
      expect(result.unsynced!.text, 'texte simple');
    });

    test('writing null clears the lyrics already there', () async {
      final file = await writeFixture('clear.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);
      await Id3Writer.writeLyrics(file.path, synced: sample);
      expect(
        Id3Reader.readLyricsFromBytes(await file.readAsBytes()).synced,
        isNotNull,
      );

      await Id3Writer.writeLyrics(file.path);

      final after = Id3Reader.readLyricsFromBytes(await file.readAsBytes());
      expect(after.synced, isNull);
      expect(after.unsynced, isNull);
      expect(Id3Tag.parse(await file.readAsBytes())!.frameById('APIC'), isNotNull);
    });

    test('repeated saves stay stable', () async {
      // The sync editor saves over and over; each pass must not accumulate
      // duplicate frames or drift the timestamps.
      final file = await writeFixture('repeat.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()], padding: 4096),
        ..._audio(),
      ]);

      for (var i = 0; i < 5; i++) {
        await Id3Writer.writeLyrics(file.path, synced: sample);
      }

      final bytes = await file.readAsBytes();
      final tag = Id3Tag.parse(bytes)!;
      expect(tag.frames.where((f) => f.id == 'SYLT'), hasLength(1));
      expect(Id3Reader.readLyricsFromBytes(bytes).synced!.lines, sample.lines);
    });
  });

  group('Id3Tag text codecs', () {
    test('decodes UTF-16 little-endian via its BOM', () {
      final bytes = Id3Tag.encodeText('héllo', Id3Encoding.utf16WithBom);
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xFE);
      expect(Id3Tag.decodeText(bytes, Id3Encoding.utf16WithBom), 'héllo');
    });

    test('decodes UTF-16 big-endian when the BOM says so', () {
      final bytes = <int>[0xFE, 0xFF, 0x00, 0x41, 0x00, 0x42];
      expect(Id3Tag.decodeText(bytes, Id3Encoding.utf16WithBom), 'AB');
    });

    test('decodes latin-1', () {
      expect(Id3Tag.decodeText([0xE9, 0x74, 0xE9], Id3Encoding.latin1), 'été');
    });

    test('picks the encoding the tag version allows', () {
      expect(Id3Encoding.unicodeFor(4), Id3Encoding.utf8);
      expect(Id3Encoding.unicodeFor(3), Id3Encoding.utf16WithBom);
    });

    test('malformed UTF-8 degrades instead of throwing', () {
      expect(
        () => Id3Tag.decodeText([0xC3, 0x28], Id3Encoding.utf8),
        returnsNormally,
      );
    });
  });
}
