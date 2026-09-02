// The Xing/LAME reader (T20).
//
// Fixtures are assembled byte by byte, like the ID3 ones: the delay and padding
// are two twelve-bit numbers packed across three bytes, and the offset of the
// LAME tag depends on the channel mode and on which optional Xing fields are
// present. Every one of those is a place to be off by a few bytes and get a
// confident wrong answer, so each is pinned by a fixture.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/audio/mp3_gapless.dart';

/// An MPEG-1 Layer III frame header at 44.1 kHz.
///
/// `0xFB`: version bits 3 (MPEG-1), layer bits 1 (III). `0x90`: bitrate index 9,
/// sample-rate index 0. The last byte carries the channel mode, which is what
/// decides the side-information size.
List<int> _frameHeader({bool mono = false}) => [
  0xFF,
  0xFB,
  0x90,
  mono ? 0xC0 : 0x00,
];

/// The three bytes that hold the delay and the padding, twelve bits each.
List<int> _packGapless(int delay, int padding) => [
  delay >> 4,
  ((delay & 0x0F) << 4) | (padding >> 8),
  padding & 0xFF,
];

/// A LAME tag: nine bytes of version string, twelve of gain and filter data,
/// then the two numbers that matter.
List<int> _lameTag({
  String encoder = 'LAME3.100',
  int delay = 576,
  int padding = 1800,
}) => [
  ...encoder.padRight(9).codeUnits.take(9),
  ...List.filled(12, 0),
  ..._packGapless(delay, padding),
  // The real tag runs to 36 bytes; the rest is CRCs and is never read.
  ...List.filled(12, 0),
];

/// A whole first frame, with the Xing fields chosen by flag.
Uint8List _frame({
  bool mono = false,
  bool withXing = true,
  bool withToc = true,
  int? frameCount = 9000,
  List<int>? lame,
  String tag = 'Xing',
}) {
  final bytes = <int>[
    ..._frameHeader(mono: mono),
    // Side information: 32 bytes in stereo, 17 in mono for MPEG-1.
    ...List.filled(mono ? 17 : 32, 0),
  ];

  if (!withXing) {
    return Uint8List.fromList([...bytes, ...List.filled(200, 0)]);
  }

  final flags =
      (frameCount != null ? 0x01 : 0) | 0x02 | (withToc ? 0x04 : 0) | 0x08;

  bytes.addAll(tag.codeUnits);
  bytes.addAll([0, 0, 0, flags]);
  if (frameCount != null) {
    bytes.addAll([
      (frameCount >> 24) & 0xFF,
      (frameCount >> 16) & 0xFF,
      (frameCount >> 8) & 0xFF,
      frameCount & 0xFF,
    ]);
  }
  bytes.addAll(List.filled(4, 0)); // byte count
  if (withToc) bytes.addAll(List.filled(100, 0));
  bytes.addAll(List.filled(4, 0)); // quality
  bytes.addAll(lame ?? _lameTag());

  return Uint8List.fromList(bytes);
}

void main() {
  group('the two numbers T20 is about', () {
    test('delay and padding are unpacked from their twelve-bit fields', () {
      final info = Mp3GaplessReader.parse(_frame())!;

      expect(info.hasXingHeader, isTrue);
      expect(info.encoder, 'LAME3.100');
      expect(info.encoderDelay, 576);
      expect(info.encoderPadding, 1800);
    });

    test('the packing is not symmetric, so both halves are checked', () {
      // A delay whose low nibble is non-zero shares a byte with the padding's
      // high nibble. Swapping the two shifts would still round-trip a value
      // like 576/1800, where that nibble is zero.
      final info = Mp3GaplessReader.parse(
        _frame(lame: _lameTag(delay: 4095, padding: 4095)),
      )!;
      expect(info.encoderDelay, 4095);
      expect(info.encoderPadding, 4095);

      final odd = Mp3GaplessReader.parse(
        _frame(lame: _lameTag(delay: 1105, padding: 1)),
      )!;
      expect(odd.encoderDelay, 1105);
      expect(odd.encoderPadding, 1);
    });

    test('the delay in milliseconds is small — the point of the ticket', () {
      // 576 samples at 44.1 kHz is 13 ms. The lag reported against Musicolet
      // reached 200 ms, which is why the polling interval was the cause and this
      // never could have been.
      final info = Mp3GaplessReader.parse(_frame())!;
      expect(info.encoderDelayDuration!.inMilliseconds, 13);
    });
  });

  group('finding the tag at all', () {
    test('mono puts the Xing header fifteen bytes earlier', () {
      // MPEG-1 mono carries 17 bytes of side information against 32 in stereo.
      // Assuming 32 would read the delay out of the middle of the seek table.
      final info = Mp3GaplessReader.parse(_frame(mono: true))!;
      expect(info.encoderDelay, 576);
      expect(info.encoderPadding, 1800);
    });

    test('no seek table puts the LAME tag a hundred bytes earlier', () {
      final info = Mp3GaplessReader.parse(_frame(withToc: false))!;
      expect(info.encoderDelay, 576);
    });

    test('no frame-count field shifts it again', () {
      final info = Mp3GaplessReader.parse(_frame(frameCount: null))!;
      expect(info.frameCount, isNull);
      expect(info.encoderDelay, 576);
    });

    test('an Info header is read like a Xing one', () {
      // Same layout; the four letters differ only to say the file is CBR.
      final info = Mp3GaplessReader.parse(_frame(tag: 'Info'))!;
      expect(info.hasXingHeader, isTrue);
      expect(info.encoderDelay, 576);
    });
  });

  group('what it refuses to guess', () {
    test('an unknown encoder string yields no delay, not a wrong one', () {
      // An unrecognised string here usually means the offset arithmetic landed
      // somewhere else. Reading twelve-bit numbers out of arbitrary bytes would
      // produce a confident wrong answer instead of an absent one.
      final info = Mp3GaplessReader.parse(
        _frame(lame: _lameTag(encoder: 'Xyzzy1.0')),
      )!;
      expect(info.hasXingHeader, isTrue);
      expect(info.encoderDelay, isNull);
      expect(info.encoderPadding, isNull);
      expect(info.describe(), contains('sans champ LAME'));
    });

    test('a frame with no Xing header still reports its sample rate', () {
      final info = Mp3GaplessReader.parse(_frame(withXing: false))!;
      expect(info.hasXingHeader, isFalse);
      expect(info.sampleRate, 44100);
      expect(info.encoderDelay, isNull);
      expect(info.duration, isNull);
      expect(info.describe(), contains("pas d'en-tête Xing"));
    });

    test('bytes that are not an MPEG frame read as nothing', () {
      expect(Mp3GaplessReader.parse(Uint8List(0)), isNull);
      expect(Mp3GaplessReader.parse(Uint8List.fromList([1, 2, 3])), isNull);
      // A sync word followed by a reserved layer is not a frame.
      expect(
        Mp3GaplessReader.parse(
          Uint8List.fromList([0xFF, 0xF9, 0x90, 0x00, ...List.filled(64, 0)]),
        ),
        isNull,
      );
    });

    test('a truncated LAME tag yields no delay rather than an exception', () {
      final full = _frame();
      final cut = Uint8List.sublistView(full, 0, full.length - 20);
      final info = Mp3GaplessReader.parse(cut)!;
      expect(info.hasXingHeader, isTrue);
      expect(info.encoderDelay, isNull);
    });
  });

  group('the exact duration', () {
    test('comes from the frame count, not from an average bitrate', () {
      // 9000 frames x 1152 samples / 44100 Hz.
      final info = Mp3GaplessReader.parse(_frame())!;
      expect(info.frameCount, 9000);
      expect(info.duration!.inMilliseconds, 235102);
    });
  });

  group('reading a file', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('musync_gapless_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<File> write(String name, List<int> bytes) async {
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes);
      return file;
    }

    test('an ID3v2 tag is skipped by its declared size', () async {
      // The tag body deliberately contains 0xFF 0xFB — an embedded JPEG cover
      // almost always does. Scanning for a sync word instead of trusting the
      // declared size would find that one and parse noise.
      final body = <int>[0xFF, 0xFB, 0x90, 0x00, ...List.filled(96, 0)];
      final tag = <int>[
        0x49, 0x44, 0x33, // "ID3"
        3, 0, 0, // v2.3, no flags
        0, 0, 0, body.length, // synchsafe size, small enough to be literal
        ...body,
      ];

      final file = await write('tagged.mp3', [...tag, ..._frame()]);
      final info = await Mp3GaplessReader.read(file.path);

      expect(info, isNotNull);
      expect(info!.encoderDelay, 576);
      expect(info.frameCount, 9000);
    });

    test('a file with no frame at all reads as null', () async {
      final file = await write('empty.mp3', List.filled(64, 0));
      expect(await Mp3GaplessReader.read(file.path), isNull);
    });

    test('a missing file reads as null rather than throwing', () async {
      expect(
        await Mp3GaplessReader.read(
          '${dir.path}${Platform.pathSeparator}nope.mp3',
        ),
        isNull,
      );
    });
  });
}
