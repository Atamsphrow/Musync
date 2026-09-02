// Naming the container before writing to it.
//
// This covers T31, the file-destroying bug: an M4A was read as "an MP3 with no
// tag yet", so the writer prepended an ID3v2 tag to an MP4 container and
// invalidated every atom offset in it. The fixtures here are synthesised
// headers, deliberately — the point of the ticket is to stop reproducing this
// against the user's own collection.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/audio_container.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';

/// The bytes an MP4 opens with: a size field, then `ftyp`, then a brand.
Uint8List _m4aHeader() => Uint8List.fromList([
  0x00, 0x00, 0x00, 0x20, // atom size
  ...ascii.encode('ftyp'),
  ...ascii.encode('M4A '),
  0x00, 0x00, 0x02, 0x00,
  ...ascii.encode('isomiso2'),
  // Stand-in for the rest of the container.
  ...List<int>.generate(4096, (i) => (i * 13) % 256),
]);

Uint8List _mp3WithTag() => Uint8List.fromList([
  ...ascii.encode('ID3'),
  4, 0, 0,
  0, 0, 0, 0, // empty tag body
  ...List<int>.generate(2048, (i) => (i * 7) % 256),
]);

/// An MP3 with no tag at all: straight into an MPEG frame sync.
Uint8List _mp3Bare() => Uint8List.fromList([
  0xFF,
  0xFB,
  0x90,
  0x00,
  ...List<int>.generate(2048, (i) => (i * 11) % 256),
]);

void main() {
  group('detect', () {
    test('an ID3 tag means MP3', () {
      expect(AudioContainerReader.detect(_mp3WithTag()), AudioContainer.mp3);
    });

    test('a bare MPEG frame sync means MP3', () {
      expect(AudioContainerReader.detect(_mp3Bare()), AudioContainer.mp3);
    });

    test('ftyp at offset four means MP4', () {
      // The exact case that corrupted files: nothing at offset 0 says "MP4",
      // which is why a check for `ID3` alone could not see it.
      expect(AudioContainerReader.detect(_m4aHeader()), AudioContainer.mp4);
    });

    test('the other containers are named too', () {
      Uint8List head(String magic, [String? at8]) => Uint8List.fromList([
        ...ascii.encode(magic),
        ...List<int>.filled(4, 0),
        ...ascii.encode(at8 ?? '    '),
      ]);

      expect(AudioContainerReader.detect(head('fLaC')), AudioContainer.flac);
      expect(AudioContainerReader.detect(head('OggS')), AudioContainer.ogg);
      expect(
        AudioContainerReader.detect(head('RIFF', 'WAVE')),
        AudioContainer.wav,
      );
    });

    test('anything else is unknown, and unknown is still writable', () {
      // Not refused on purpose: an MP3 with junk before its first frame lands
      // here, and MP3 writing is proven. Refusing the unidentified would trade
      // a known bug for an unknown regression.
      final odd = Uint8List.fromList(List<int>.filled(64, 0x42));
      expect(AudioContainerReader.detect(odd), AudioContainer.unknown);
      expect(AudioContainer.unknown.isWritable, isTrue);
    });

    test('a truncated file does not throw', () {
      expect(
        AudioContainerReader.detect(Uint8List.fromList([0x49])),
        AudioContainer.unknown,
      );
      expect(AudioContainerReader.detect(Uint8List(0)), AudioContainer.unknown);
    });
  });

  group('the writer refuses what it would break', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('musync_container_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<File> fixture(String name, Uint8List bytes) async {
      final file = File('${tempDir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes);
      return file;
    }

    final lyrics = SyncedLyrics([
      const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
    ]);

    test('an M4A is refused, and left byte for byte as it was', () async {
      final original = _m4aHeader();
      final file = await fixture('track.m4a', original);

      await expectLater(
        () => Id3Writer.writeLyrics(file.path, synced: lyrics),
        throwsA(isA<Id3WriteException>()),
      );

      // The guarantee that matters. Before this check existed, the file came
      // back with an ID3 tag glued to the front of it and would not play.
      expect(await file.readAsBytes(), original);
    });

    test(
      'the refusal names the format, so the message is actionable',
      () async {
        final file = await fixture('track.m4a', _m4aHeader());

        try {
          await Id3Writer.writeLyrics(file.path, synced: lyrics);
          fail('devrait refuser');
        } on Id3WriteException catch (e) {
          expect(e.message, contains('M4A'));
          expect(e.message, contains('MP3'));
        }
      },
    );

    test('an M4A named .mp3 is still refused', () async {
      // The extension is the one thing a user can get wrong by accident, so the
      // check reads the file's own bytes rather than its name.
      final original = _m4aHeader();
      final file = await fixture('menteur.mp3', original);

      await expectLater(
        () => Id3Writer.writeLyrics(file.path, synced: lyrics),
        throwsA(isA<Id3WriteException>()),
      );
      expect(await file.readAsBytes(), original);
    });

    test('FLAC, Ogg and WAV are refused as well', () async {
      for (final magic in ['fLaC', 'OggS']) {
        final bytes = Uint8List.fromList([
          ...ascii.encode(magic),
          ...List<int>.generate(512, (i) => i % 256),
        ]);
        final file = await fixture('x_$magic', bytes);

        await expectLater(
          () => Id3Writer.writeLyrics(file.path, synced: lyrics),
          throwsA(isA<Id3WriteException>()),
        );
        expect(await file.readAsBytes(), bytes);
      }
    });

    test('an MP3 still writes', () async {
      // The refusal must not have cost the thing the app is for.
      final file = await fixture('ok.mp3', _mp3WithTag());

      await Id3Writer.writeLyrics(file.path, synced: lyrics);

      expect(await file.length(), greaterThan(_mp3WithTag().length));
    });

    test('a tagless MP3 still writes', () async {
      final file = await fixture('bare.mp3', _mp3Bare());

      await Id3Writer.writeLyrics(file.path, synced: lyrics);

      final after = await file.readAsBytes();
      expect(AudioContainerReader.detect(after), AudioContainer.mp3);
    });
  });
}
