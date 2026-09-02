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

  /// The frame's second flag byte. Zero for almost every real frame; the tests
  /// that set it are the ones about v2.3 and v2.4 disagreeing on what its bits
  /// mean.
  final int flagsLo;

  const _Frame(this.id, this.body, {this.flagsLo = 0});
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
    body.add(
      major == 4
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
            ],
    );
    body.add([0, frame.flagsLo]); // frame flags
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
        frames: [
          _artworkFrame(),
          const _Frame('TIT2', [0, 65, 66]),
        ],
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
        frames: [
          const _Frame('TIT2', [0, 65]),
        ],
        padding: 512,
      );

      expect(Id3Tag.parse(bytes)!.frames, hasLength(1));
    });

    test('skips the footer when locating the audio', () {
      final bytes = _tagBytes(
        major: 4,
        frames: [
          const _Frame('TIT2', [0, 65]),
        ],
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
          _Frame('TIT2', [0, 0xFF, 0x00, 0x41]),
        ],
        headerFlags: 0x80,
      );

      final tag = Id3Tag.parse(bytes)!;

      expect(tag.frameById('TIT2')!.body, [0, 0xFF, 0x41]);
    });
  });

  group('writeLyrics preserves the rest of the file', () {
    test(
      'leaves a v2.3 artwork frame byte-identical and keeps the version',
      () async {
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
      },
    );

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

      expect(
        Id3Reader.readLyricsFromBytes(await file.readAsBytes()).synced!.lines,
        hasLength(200),
      );
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
      await Id3Writer.writeLyrics(
        file.path,
        synced: synced,
        unsynced: unsynced,
      );
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

    test('both frames are written, and the timings win', () async {
      // Untimed text handed in beside a timed lyric does not survive: the plain
      // frame's job is to carry the timings for players that ignore SYLT, so
      // the writer replaces it with LRC rather than let a track go out
      // looking unsynchronised. See "plain text supplied next to timings".
      final result = await roundTrip(
        4,
        synced: sample,
        unsynced: const UnsyncedLyrics('texte simple'),
      );

      expect(result.synced!.lines, hasLength(3));
      expect(result.unsynced!.text, isNot(contains('texte simple')));
      expect(result.unsynced!.text, sample.toPlainText());
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
      expect(
        Id3Tag.parse(await file.readAsBytes())!.frameById('APIC'),
        isNotNull,
      );
    });

    test('plain text alone wipes the timings that were there (T16)', () async {
      // Not a bug in the writer: replacing the whole lyric state is what the
      // sync editor needs, and it must be able to clear a timing. It is a bug
      // in whoever calls it with an online match that only has plain text — the
      // file comes back as "texte seul" and an evening of calibration is gone.
      // That is why `embedLyrics` refuses this by default and asks first; this
      // test is the reason it has to.
      final file = await writeFixture('downgrade.mp3', [
        ..._tagBytes(major: 3, frames: []),
        ..._audio(),
      ]);
      await Id3Writer.writeLyrics(file.path, synced: sample);
      expect(
        Id3Reader.readLyricsFromBytes(await file.readAsBytes()).synced,
        isNotNull,
      );

      await Id3Writer.writeLyrics(
        file.path,
        unsynced: const UnsyncedLyrics('Juste du texte'),
      );

      final after = Id3Reader.readLyricsFromBytes(await file.readAsBytes());
      expect(after.synced, isNull, reason: 'le calage a disparu');
      expect(after.unsynced?.text, 'Juste du texte');
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

  group('SYLT line separator', () {
    // SYLT carries no line-break concept of its own: a syllable begins a new
    // line only because its text starts with a newline. Musync's reader strips
    // that newline whether or not it is there, so a round trip passes either
    // way — which is exactly how the writer came to omit it, and why Musicolet
    // saw one unbroken run of syllables and fell back to the plain USLT text.
    //
    // These read the raw frame instead of trusting a round trip.
    final pair = SyncedLyrics([
      const LyricLine(timestamp: Duration.zero, text: 'Ligne A'),
      const LyricLine(timestamp: Duration(seconds: 5), text: 'Ligne B'),
    ]);

    Future<Uint8List> syltBody(int major) async {
      final file = await writeFixture('sep$major.mp3', [
        ..._tagBytes(major: major, frames: [_artworkFrame()]),
        ..._audio(),
      ]);
      await Id3Writer.writeLyrics(file.path, synced: pair);
      return Id3Tag.parse(await file.readAsBytes())!.frameById('SYLT')!.body;
    }

    test('v2.4 opens every syllable with a newline (UTF-8)', () async {
      final body = await syltBody(4);
      // Header is encoding, 3-byte language, timestamp format, content type,
      // then a one-byte terminator closing the empty descriptor.
      expect(body[0], Id3Encoding.utf8);
      expect(body[6], 0);
      expect(body[7], 0x0A, reason: 'la 1re syllabe doit commencer par \\n');

      // One per line. Safe to count here because neither timestamp in the
      // fixture (0 ms and 5000 ms) contains an 0x0A byte.
      expect(body.where((b) => b == 0x0A), hasLength(2));
    });

    test('v2.3 opens every syllable with a newline, after the BOM', () async {
      final body = await syltBody(3);
      expect(body[0], Id3Encoding.utf16WithBom);
      // UTF-16 terminates on a null pair, so the descriptor eats bytes 6 and 7.
      expect([body[8], body[9]], [0xFF, 0xFE], reason: 'BOM little-endian');
      expect([body[10], body[11]], [0x0A, 0x00], reason: '\\n en UTF-16LE');
    });

    test('the separator never reaches the lyric the user sees', () async {
      final file = await writeFixture('sepread.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);
      await Id3Writer.writeLyrics(file.path, synced: pair);

      final read = Id3Reader.readLyricsFromBytes(await file.readAsBytes());
      expect(read.synced!.lines.map((l) => l.text), ['Ligne A', 'Ligne B']);
    });
  });

  group('lines with no timestamp', () {
    // A structural marker belongs to the words but must never be sung. It stays
    // in the plain text and is left out of the timings entirely.
    const lines = [
      LyricLine(timestamp: Duration.zero, text: 'Ligne A'),
      LyricLine(timestamp: null, text: '[Refrain]'),
      LyricLine(timestamp: Duration(seconds: 5), text: 'Ligne B'),
    ];

    test('SyncedLyrics drops them on construction', () {
      final lyrics = SyncedLyrics(lines);
      expect(lyrics.lines.map((l) => l.text), ['Ligne A', 'Ligne B']);
    });

    test('kept out of SYLT, kept in USLT', () async {
      final file = await writeFixture('untimed.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);

      // Written the way the sync editor writes it: LRC, with the untimed line
      // emitted bare. That form matters — the writer only keeps a caller's own
      // text when it already carries the timings, and plain text handed in
      // beside a timed lyric is replaced by LRC derived from it. Supplying
      // plain text here would have tested a path the app never takes.
      await Id3Writer.writeLyrics(
        file.path,
        synced: SyncedLyrics(lines),
        unsynced: const UnsyncedLyrics(
          '[00:00.00]Ligne A\n[Refrain]\n[00:05.00]Ligne B',
        ),
      );

      final read = Id3Reader.readLyricsFromBytes(await file.readAsBytes());
      expect(
        read.synced!.lines.map((l) => l.text),
        ['Ligne A', 'Ligne B'],
        reason: 'le marqueur ne doit pas devenir une entrée SYLT',
      );

      // The reader strips the prefixes, so what comes back is the words alone —
      // marker included, which is the point.
      expect(
        read.unsynced!.text,
        contains('[Refrain]'),
        reason: 'mais il doit rester dans les paroles simples',
      );
    });

    test('a lyric that is nothing but markers writes no SYLT at all', () async {
      final file = await writeFixture('markers.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);

      await Id3Writer.writeLyrics(
        file.path,
        synced: SyncedLyrics(const [
          LyricLine(timestamp: null, text: '[Intro]'),
          LyricLine(timestamp: null, text: '[Refrain]'),
        ]),
      );

      final bytes = await file.readAsBytes();
      expect(Id3Tag.parse(bytes)!.frameById('SYLT'), isNull);
      // And the artwork is still there, which is the invariant that governs
      // this whole module.
      expect(Id3Tag.parse(bytes)!.frameById('APIC'), isNotNull);
    });
  });

  group('timings carried in the plain frame', () {
    // The interop story, from both ends.
    //
    // SYLT is what the spec intends, but Musicolet — and plenty of others —
    // ignore it and read `[mm:ss.xx]` prefixes out of USLT instead. So Musync
    // writes both, and has to be able to read back what it wrote: a file whose
    // only timings live inside the plain frame must come out synchronised, not
    // as a lyric with brackets in the middle of the words.
    final sample = SyncedLyrics([
      const LyricLine(timestamp: Duration.zero, text: 'Ouverture'),
      const LyricLine(
        timestamp: Duration(seconds: 12, milliseconds: 340),
        text: 'Deuxième ligne',
      ),
    ]);

    test('writing synced lyrics puts LRC in USLT as well as SYLT', () async {
      final file = await writeFixture('both.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);
      await Id3Writer.writeLyrics(file.path, synced: sample);

      final tag = Id3Tag.parse(await file.readAsBytes())!;
      expect(tag.frameById('SYLT'), isNotNull, reason: 'SYLT attendu');

      final uslt = tag.frameById('USLT');
      expect(uslt, isNotNull, reason: 'USLT attendu même sans texte fourni');

      // Skip encoding byte, 3-byte language and the empty descriptor.
      final body = uslt!.decodedBody;
      final text = Id3Tag.decodeText(body.sublist(5), body[0]);
      expect(text, contains('[00:12.34]Deuxième ligne'));
    });

    test('a USLT holding LRC reads back as synchronised', () async {
      const lrc = '[00:00.00]Ouverture\n[00:12.34]Deuxième ligne';
      final file = await writeFixture('lrconly.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);
      // Written as plain text on purpose — no SYLT at all, which is how files
      // tagged by other apps arrive.
      await Id3Writer.writeLyrics(
        file.path,
        unsynced: const UnsyncedLyrics(lrc),
      );

      final read = Id3Reader.readLyricsFromBytes(await file.readAsBytes());

      expect(read.synced, isNotNull, reason: 'les timings doivent être vus');
      expect(read.synced!.lines.map((l) => l.text), [
        'Ouverture',
        'Deuxième ligne',
      ]);
      expect(
        read.synced!.lines.last.timestamp,
        const Duration(seconds: 12, milliseconds: 340),
      );

      // And the plain side comes back without the brackets, so nothing shows
      // them to the user as if they were words.
      expect(read.unsynced!.text, 'Ouverture\nDeuxième ligne');
    });

    test('plain text supplied next to timings is replaced by LRC', () async {
      // The regression a probe against real files caught. LRCLIB returns the
      // timed lyric and a plain transcription side by side, and the search
      // screen passed both — so the writer, which trusted whatever text it was
      // given, wrote a USLT with no timings at all. A track fetched online
      // still showed up unsynchronised in Musicolet, which is the exact failure
      // T3 exists to fix.
      final file = await writeFixture('supplied_plain.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);

      await Id3Writer.writeLyrics(
        file.path,
        synced: sample,
        unsynced: UnsyncedLyrics(sample.toPlainText()),
      );

      final read = Id3Reader.readLyricsFromBytes(await file.readAsBytes());
      expect(read.synced, isNotNull);
      expect(
        read.synced!.lines.last.timestamp,
        const Duration(seconds: 12, milliseconds: 340),
        reason: 'les timings doivent survivre au texte fourni',
      );
    });

    test('LRC text supplied by the caller is kept, markers and all', () async {
      // The other half of the same rule. The sync editor's text already carries
      // the timings, and it holds something SyncedLyrics cannot: lines the user
      // deliberately left untimed. Deriving from `synced` here would drop them.
      const withMarker =
          '[Refrain]\n[00:00.00]Ouverture\n'
          '[00:12.34]Deuxième ligne';
      final file = await writeFixture('supplied_lrc.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);

      await Id3Writer.writeLyrics(
        file.path,
        synced: sample,
        unsynced: const UnsyncedLyrics(withMarker),
      );

      final tag = Id3Tag.parse(await file.readAsBytes())!;
      final body = tag.frameById('USLT')!.decodedBody;
      final text = Id3Tag.decodeText(
        body.sublist(4 + Id3Encoding.terminatorLength(body[0])),
        body[0],
      );
      expect(
        text,
        contains('[Refrain]'),
        reason: 'marqueur non horodaté perdu',
      );
      expect(text, contains('[00:12.34]Deuxième ligne'));
    });

    test('plain lyrics with no timings stay plain', () async {
      final file = await writeFixture('plainonly.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);
      await Id3Writer.writeLyrics(
        file.path,
        unsynced: const UnsyncedLyrics('Une chanson\nsans horodatage'),
      );

      final read = Id3Reader.readLyricsFromBytes(await file.readAsBytes());
      expect(read.synced, isNull);
      expect(read.unsynced!.text, 'Une chanson\nsans horodatage');
    });
  });

  group('readLyricsFrames — the reader that skips artwork', () {
    // A shortcut taken for speed has to give the same answer as the slow path,
    // or the catalogue would sort tracks into different tabs depending on which
    // reader happened to look at them.
    final sample = SyncedLyrics([
      const LyricLine(timestamp: Duration.zero, text: 'Première'),
      const LyricLine(timestamp: Duration(seconds: 9), text: 'Seconde'),
    ]);

    Future<void> expectAgreement(File file) async {
      final streamed = await Id3Reader.readLyricsFrames(file.path);
      final whole = await Id3Reader.readLyrics(file.path);

      expect(streamed.synced?.lines, whole.synced?.lines);
      expect(streamed.unsynced?.text, whole.unsynced?.text);
    }

    test('agrees with the whole-tag reader on v2.4', () async {
      final file = await writeFixture('fast24.mp3', [
        ..._tagBytes(major: 4, frames: [_artworkFrame()]),
        ..._audio(),
      ]);
      await Id3Writer.writeLyrics(file.path, synced: sample);

      await expectAgreement(file);
      expect(
        (await Id3Reader.readLyricsFrames(file.path)).synced!.lines,
        sample.lines,
      );
    });

    test('agrees on v2.3, where frame sizes are big-endian', () async {
      final file = await writeFixture('fast23.mp3', [
        ..._tagBytes(major: 3, frames: [_artworkFrame()]),
        ..._audio(),
      ]);
      await Id3Writer.writeLyrics(file.path, synced: sample);

      await expectAgreement(file);
    });

    test('finds lyrics sitting behind the artwork', () async {
      // Frame order is the whole risk of walking rather than parsing: seeking
      // past a body by the wrong number of bytes desyncs everything after it,
      // and artwork is exactly the frame big enough to hide the mistake.
      final file = await writeFixture('behind.mp3', [
        ..._tagBytes(
          major: 4,
          frames: [
            _artworkFrame(),
            const _Frame('TIT2', [0, 65, 66]),
            _artworkFrame(),
          ],
        ),
        ..._audio(),
      ]);
      await Id3Writer.writeLyrics(file.path, synced: sample);

      final read = await Id3Reader.readLyricsFrames(file.path);
      expect(read.synced!.lines, sample.lines);
    });

    test('falls back rather than misread an unsynchronised tag', () async {
      final file = await writeFixture('unsync.mp3', [
        ..._tagBytes(
          major: 3,
          frames: const [
            _Frame('TIT2', [0, 0xFF, 0x00, 0x41]),
          ],
          headerFlags: 0x80,
        ),
        ..._audio(),
      ]);

      // No lyrics in it — the point is that it comes back cleanly instead of
      // walking off the end of a body whose declared size counts stuffed bytes.
      final read = await Id3Reader.readLyricsFrames(file.path);
      expect(read.synced, isNull);
      expect(read.unsynced, isNull);
    });

    test('a file with no tag at all is not an error', () async {
      final file = await writeFixture('notag.mp3', _audio());

      final read = await Id3Reader.readLyricsFrames(file.path);
      expect(read.synced, isNull);
      expect(read.unsynced, isNull);
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

  // Regressions found by reading the container code with fresh eyes rather than
  // by a failure in the field. Each one loses data quietly, which is the worst
  // way for a tag writer to be wrong.
  group('a frame that says nothing', () {
    test('an empty frame does not end the tag', () {
      // `size <= 0` was treated as the end of the frame list, so a tagger that
      // emits an empty frame cost every frame behind it — and APIC is usually
      // written last, so what it cost was the cover art.
      final bytes = _tagBytes(
        major: 3,
        frames: [const _Frame('TIT2', []), _artworkFrame()],
      );

      final tag = Id3Tag.parse(bytes)!;
      expect(tag.frames.map((f) => f.id), ['TIT2', 'APIC']);
      expect(tag.frameById('APIC')!.body, hasLength(200));
    });

    test('and it survives a rewrite', () async {
      final dir = await Directory.systemTemp.createTemp('musync_empty_frame_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}t.mp3');
      await file.writeAsBytes([
        ..._tagBytes(
          major: 3,
          frames: [const _Frame('TIT2', []), _artworkFrame()],
          padding: 4096,
        ),
        ..._audio(),
      ]);

      await Id3Writer.writeLyrics(
        file.path,
        synced: SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
        ]),
      );

      final after = Id3Tag.parse(await file.readAsBytes())!;
      expect(after.frameById('APIC')!.body, hasLength(200));
    });
  });

  group('frame flags mean different things per version', () {
    /// A USLT body: encoding, language, empty descriptor, then the text.
    List<int> uslt(String text) => [
      0, // latin-1
      ...ascii.encode('eng'),
      0, // empty descriptor
      ...latin1.encode(text),
    ];

    test('a v2.3 compressed frame is opaque, not parsed as plain text', () {
      // 0x80 is compression in v2.3; in v2.4 the same bit means nothing. The
      // flags were read with v2.4's layout whatever the tag said, so this frame
      // looked ordinary and its compressed bytes were decoded as words.
      final tag = Id3Tag.parse(
        _tagBytes(
          major: 3,
          frames: [
            _Frame('USLT', uslt('des octets compressés'), flagsLo: 0x80),
          ],
        ),
      )!;

      expect(tag.frameById('USLT')!.isOpaque, isTrue);
    });

    test('the same bit on a v2.4 frame means nothing', () {
      final tag = Id3Tag.parse(
        _tagBytes(
          major: 4,
          frames: [_Frame('USLT', uslt('lisible'), flagsLo: 0x80)],
        ),
      )!;

      expect(tag.frameById('USLT')!.isOpaque, isFalse);
    });

    test('v2.4 compression is 0x08, and is refused', () {
      final tag = Id3Tag.parse(
        _tagBytes(
          major: 4,
          frames: [_Frame('USLT', uslt('compressé'), flagsLo: 0x08)],
        ),
      )!;

      expect(tag.frameById('USLT')!.isOpaque, isTrue);
    });

    test('a grouped frame has its group byte stripped', () {
      // Grouping prepends one byte. It was not being removed, so every field of
      // the frame sat one byte late: the encoding byte read as part of the
      // language and the text came out as noise.
      final tag = Id3Tag.parse(
        _tagBytes(
          major: 4,
          frames: [
            _Frame('USLT', [0x42, ...uslt('Une')], flagsLo: 0x40),
          ],
        ),
      )!;

      final body = tag.frameById('USLT')!.decodedBody;
      expect(body.first, 0, reason: 'octet de groupe retire');
      expect(latin1.decode(body.sublist(5)), 'Une');
    });

    test('a reader on such a file finds the lyrics', () {
      final bytes = _tagBytes(
        major: 4,
        frames: [
          _Frame('USLT', [0x07, ...uslt('Paroles groupées')], flagsLo: 0x40),
        ],
      );

      final pair = Id3Reader.readLyricsFromBytes(bytes);
      expect(pair.unsynced?.text, 'Paroles groupées');
    });
  });

  group('unsynchronisation, once and only once', () {
    test('a tag-level pass clears the per-frame flag', () {
      // Both readings of a whole-tag pass hand back de-unsynchronised bodies. A
      // frame still flagged as unsynchronised would be stripped a second time on
      // the way back in — and the writer copies flags verbatim, so that false
      // claim would be written into the user's file.
      final body = [
        0,
        ...ascii.encode('eng'),
        0,
        0xFF,
        0x00,
        0xFE, // an $FF $00 pair the tag-level pass will collapse
      ];
      final tag = Id3Tag.parse(
        _tagBytes(
          major: 4,
          frames: [_Frame('USLT', body, flagsLo: 0x02)],
          headerFlags: 0x80,
        ),
      )!;

      final frame = tag.frameById('USLT')!;
      expect(frame.flagsLo & 0x02, 0);
      // And the body is de-unsynchronised exactly once: the stuffed $00 is gone
      // and the $FE behind it survives.
      expect(frame.decodedBody.last, 0xFE);
    });
  });
}
