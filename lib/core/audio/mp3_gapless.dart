/// The encoder delay and padding an MP3 declares about itself (T20).
///
/// LAME — and the ffmpeg encoders that copied its tag — records, in the first
/// frame, how many samples of technical silence it had to add at the start and
/// the end. Those samples are part of the decoded stream but not of the music,
/// so a player that ignores them is offset by exactly that much.
///
/// This module only *reads*. Whether the delay should be subtracted anywhere is
/// a separate decision, and deliberately not taken here — see
/// [Mp3GaplessInfo.encoderDelay].
library;

import 'dart:io';
import 'dart:typed_data';

/// What the first frame of an MP3 says about itself.
class Mp3GaplessInfo {
  /// Samples of silence the encoder added at the start, from the LAME tag.
  ///
  /// Null when the file carries no LAME-style tag. **Not** applied to playback
  /// positions anywhere in this app, and that is a considered choice rather
  /// than an omission: ExoPlayer's MP3 extractor reads these same two fields
  /// and hands them to the audio sink, which trims them — so subtracting them
  /// again in Dart would move the lyrics by the delay in the wrong direction.
  ///
  /// It is read so the value can be seen. The constant lag reported in T20 was
  /// measured at up to 200 ms; a typical LAME delay is 576 + 529 = 1105
  /// samples, which is 25 ms at 44.1 kHz — an order of magnitude too small to
  /// be the symptom. The polling interval was.
  final int? encoderDelay;

  /// Samples of silence at the end. Same provenance, same caveat.
  final int? encoderPadding;

  /// The encoder's own version string, e.g. `LAME3.100` or `Lavf58.29`.
  final String? encoder;

  /// Audio frames, from the Xing header. The exact count, where a
  /// bitrate-based figure is only an estimate.
  final int? frameCount;

  final int sampleRate;

  /// Samples per frame — 1152 for MPEG-1 Layer III, 576 for MPEG-2/2.5.
  final int samplesPerFrame;

  /// True when the first frame carries a `Xing` or `Info` header at all.
  final bool hasXingHeader;

  const Mp3GaplessInfo({
    required this.sampleRate,
    required this.samplesPerFrame,
    required this.hasXingHeader,
    this.encoderDelay,
    this.encoderPadding,
    this.encoder,
    this.frameCount,
  });

  /// The delay expressed as a duration, or null when unknown.
  Duration? get encoderDelayDuration {
    final delay = encoderDelay;
    if (delay == null || sampleRate <= 0) return null;
    return Duration(microseconds: (delay * 1000000 / sampleRate).round());
  }

  /// Duration from the exact frame count, or null without a Xing header.
  ///
  /// More reliable than a bitrate estimate on a VBR file — which is exactly the
  /// case where an average-bitrate duration is worst.
  Duration? get duration {
    final frames = frameCount;
    if (frames == null || sampleRate <= 0) return null;
    final samples = frames * samplesPerFrame;
    return Duration(microseconds: (samples * 1000000 / sampleRate).round());
  }

  /// One line for the diagnostic card. Says what is absent rather than guessing.
  String describe() {
    final String gapless;
    if (!hasXingHeader) {
      gapless = "pas d'en-tête Xing";
    } else if (encoderDelay == null) {
      gapless = "en-tête Xing sans champ LAME";
    } else {
      gapless =
          "delay $encoderDelay éch. "
          "(${encoderDelayDuration!.inMilliseconds} ms), "
          "padding $encoderPadding éch.";
    }

    return [
      "${(sampleRate / 1000).toStringAsFixed(1)} kHz",
      ?encoder,
      gapless,
    ].join(" · ");
  }
}

/// Bitrates in kbps by index, for layer III. MPEG-1 and MPEG-2/2.5 differ.
const List<int> _bitratesMpeg1 = [
  0,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
  0,
];
const List<int> _bitratesMpeg2 = [
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
  0,
];

/// Sample rates by MPEG version and index.
const List<List<int>> _sampleRates = [
  [11025, 12000, 8000], // MPEG 2.5
  [], // reserved
  [22050, 24000, 16000], // MPEG 2
  [44100, 48000, 32000], // MPEG 1
];

abstract final class Mp3GaplessReader {
  /// How much of the file to read. The first frame plus its Xing/LAME tag
  /// cannot exceed one frame, and a layer III frame cannot exceed 1441 bytes;
  /// 4 KB also covers a little junk before the first sync word.
  static const int _probeLength = 4096;

  /// Reads the first frame of [path]. Null when there is nothing to read there.
  ///
  /// Never throws. A file that cannot be parsed is not something the user can
  /// act on, and this is only ever a diagnostic.
  static Future<Mp3GaplessInfo?> read(String path) async {
    RandomAccessFile? handle;
    try {
      handle = await File(path).open();
      final length = await handle.length();

      final start = await _audioStart(handle, length);
      if (start >= length) return null;

      await handle.setPosition(start);
      final bytes = await handle.read(
        (length - start).clamp(0, _probeLength).toInt(),
      );
      return parse(bytes);
    } catch (_) {
      return null;
    } finally {
      try {
        await handle?.close();
      } catch (_) {
        // Nothing useful to do about a handle that will be collected anyway.
      }
    }
  }

  /// Where the audio starts: past an ID3v2 tag if there is one.
  ///
  /// Skipped by its declared size rather than by scanning, because a tag's own
  /// bytes can contain a plausible frame sync — an embedded JPEG cover almost
  /// certainly does.
  static Future<int> _audioStart(RandomAccessFile handle, int length) async {
    if (length < 10) return 0;
    await handle.setPosition(0);
    final header = await handle.read(10);
    if (header.length < 10 ||
        header[0] != 0x49 ||
        header[1] != 0x44 ||
        header[2] != 0x33) {
      return 0;
    }

    // Synchsafe: seven bits per byte.
    final size =
        (header[6] & 0x7F) << 21 |
        (header[7] & 0x7F) << 14 |
        (header[8] & 0x7F) << 7 |
        (header[9] & 0x7F);
    // A footer, when the flag says so, is another ten bytes.
    final footer = (header[5] & 0x10) != 0 ? 10 : 0;
    return 10 + size + footer;
  }

  /// Parses the first MPEG audio frame in [bytes], and its Xing/LAME tag.
  ///
  /// Visible for testing against synthetic headers: a parser for a bit-packed
  /// format has to be pinned down by bytes assembled on purpose, the same way
  /// the ID3 fixtures are.
  static Mp3GaplessInfo? parse(Uint8List bytes) {
    final frame = _findFrame(bytes);
    if (frame == null) return null;

    Mp3GaplessInfo withoutXing() => Mp3GaplessInfo(
      sampleRate: frame.sampleRate,
      samplesPerFrame: frame.samplesPerFrame,
      hasXingHeader: false,
    );

    // The Xing/Info header sits immediately after the side information.
    final xing = frame.offset + 4 + frame.sideInfoSize;
    if (xing + 8 > bytes.length) return withoutXing();

    final tag = String.fromCharCodes(bytes.sublist(xing, xing + 4));
    if (tag != 'Xing' && tag != 'Info') return withoutXing();

    final flags = _beInt32(bytes, xing + 4);
    var cursor = xing + 8;

    int? frameCount;
    if (flags & 0x01 != 0) {
      if (cursor + 4 > bytes.length) return withoutXing();
      frameCount = _beInt32(bytes, cursor);
      cursor += 4;
    }
    if (flags & 0x02 != 0) cursor += 4; // byte count
    if (flags & 0x04 != 0) cursor += 100; // seek table
    if (flags & 0x08 != 0) cursor += 4; // quality

    // The LAME extension begins here — computed from the flags rather than
    // assumed at the usual 0x9C, because a header written without the seek
    // table puts it a hundred bytes earlier.
    final lame = _readLame(bytes, cursor);

    return Mp3GaplessInfo(
      sampleRate: frame.sampleRate,
      samplesPerFrame: frame.samplesPerFrame,
      hasXingHeader: true,
      frameCount: frameCount,
      encoder: lame?.encoder,
      encoderDelay: lame?.delay,
      encoderPadding: lame?.padding,
    );
  }

  /// The LAME tag, if one is there and looks like one.
  static _Lame? _readLame(Uint8List bytes, int at) {
    // Nine bytes of version string, then twelve of gain and filter data, then
    // the three bytes that matter.
    if (at < 0 || at + 24 > bytes.length) return null;

    final encoder = String.fromCharCodes(bytes.sublist(at, at + 9)).trim();
    // Only trust the fields when a known encoder claims them. An unknown string
    // here usually means the offset arithmetic landed somewhere else, and
    // reading twelve-bit numbers out of arbitrary bytes would produce a
    // confident wrong answer instead of an absent one.
    const known = ['LAME', 'Lavc', 'Lavf', 'L3.9', 'GOGO'];
    if (!known.any(encoder.startsWith)) return null;

    // Delay and padding are packed as twelve bits each across three bytes.
    final delay = (bytes[at + 21] << 4) | (bytes[at + 22] >> 4);
    final padding = ((bytes[at + 22] & 0x0F) << 8) | bytes[at + 23];

    return _Lame(encoder: encoder, delay: delay, padding: padding);
  }

  /// The first valid frame header, or null.
  ///
  /// Scans rather than trusting offset zero: a file can carry junk between its
  /// ID3 tag and its first frame, and that is precisely the shape
  /// `audio_container.dart` decided to keep supporting.
  ///
  /// A candidate is only accepted when **a second frame follows it at exactly
  /// the length the first one declares**. Eleven bits of sync appear roughly
  /// every 2 KB of arbitrary data, so a single header is not evidence — and this
  /// probe found exactly that: a file whose first apparent frame claimed 12 kHz,
  /// a rate no music file uses, from a sync word that was not a frame at all.
  /// Two frames in a row agreeing on their own arithmetic is evidence.
  static _Frame? _findFrame(Uint8List bytes) {
    for (var i = 0; i + 4 <= bytes.length; i++) {
      if (bytes[i] != 0xFF || (bytes[i + 1] & 0xE0) != 0xE0) continue;
      final frame = _decodeHeader(bytes, i);
      if (frame == null) continue;

      final next = i + frame.length;
      // Beyond what was read, the check cannot be made. Accepting is right:
      // refusing would throw away a genuine frame near the end of the probe
      // window, and the fields are validated on their own terms besides.
      if (next + 2 > bytes.length) return frame;
      if (bytes[next] == 0xFF && (bytes[next + 1] & 0xE0) == 0xE0) return frame;
    }
    return null;
  }

  static _Frame? _decodeHeader(Uint8List bytes, int at) {
    final b1 = bytes[at + 1];
    final b2 = bytes[at + 2];
    final b3 = bytes[at + 3];

    final version = (b1 >> 3) & 0x03;
    if (version == 1) return null; // reserved
    final layer = (b1 >> 1) & 0x03;
    if (layer != 0x01) return null; // only layer III carries a Xing header

    final rateIndex = (b2 >> 2) & 0x03;
    if (rateIndex == 3) return null; // reserved

    final bitrateIndex = (b2 >> 4) & 0x0F;
    if (bitrateIndex == 0 || bitrateIndex == 0x0F) return null; // free / bad

    final isMpeg1Rate = version == 3;
    final bitrate =
        (isMpeg1Rate ? _bitratesMpeg1 : _bitratesMpeg2)[bitrateIndex] * 1000;
    if (bitrate == 0) return null;

    final mono = ((b3 >> 6) & 0x03) == 3;
    // MPEG-1 carries more side information than MPEG-2/2.5, and mono less than
    // any stereo mode. Getting this wrong puts the Xing tag at the wrong
    // offset, which is why it is spelled out rather than fixed at 32.
    final isMpeg1 = version == 3;

    final sampleRate = _sampleRates[version][rateIndex];
    final padding = (b2 >> 1) & 0x01;
    // Layer III packs 1152 samples per frame on MPEG-1 and 576 otherwise, hence
    // the two constants: bytes = samples / 8 * bitrate / sampleRate.
    final length =
        ((isMpeg1 ? 144 : 72) * bitrate / sampleRate).floor() + padding;

    return _Frame(
      offset: at,
      sampleRate: sampleRate,
      sideInfoSize: isMpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17),
      samplesPerFrame: isMpeg1 ? 1152 : 576,
      length: length,
    );
  }

  static int _beInt32(Uint8List b, int at) =>
      (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}

class _Frame {
  final int offset;
  final int sampleRate;
  final int sideInfoSize;
  final int samplesPerFrame;

  /// Frame length in bytes, from the declared bitrate — used to check that a
  /// second frame really follows.
  final int length;

  const _Frame({
    required this.offset,
    required this.sampleRate,
    required this.sideInfoSize,
    required this.samplesPerFrame,
    required this.length,
  });
}

class _Lame {
  final String encoder;
  final int delay;
  final int padding;

  const _Lame({
    required this.encoder,
    required this.delay,
    required this.padding,
  });
}
