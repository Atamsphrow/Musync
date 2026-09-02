/// Low-level ID3v2 container handling, shared by the reader and the writer.
///
/// Musync edits the user's own music files in place, so the rule this file
/// exists to enforce is: never lose a byte the app doesn't understand. Frames
/// are kept as opaque payloads and written back verbatim, and a tag keeps
/// whatever major version it arrived with — v2.3 and v2.4 disagree on how frame
/// sizes are encoded, so re-stamping a v2.3 tag as v2.4 silently corrupts every
/// frame longer than 127 bytes. Artwork, above all.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Text encodings defined by the ID3v2 spec, as stored in the first byte of a
/// text frame's body.
abstract final class Id3Encoding {
  static const int latin1 = 0;
  static const int utf16WithBom = 1;
  static const int utf16BigEndian = 2;
  static const int utf8 = 3;

  /// v2.3 predates UTF-8 in ID3: only latin-1 and UTF-16-with-BOM are legal.
  static int unicodeFor(int majorVersion) =>
      majorVersion >= 4 ? utf8 : utf16WithBom;

  /// UTF-16 terminates on a null *pair*, the single-byte encodings on one null.
  static int terminatorLength(int encoding) =>
      (encoding == utf16WithBom || encoding == utf16BigEndian) ? 2 : 1;
}

/// One frame with its 10-byte header stripped off.
class Id3Frame {
  final String id;

  /// The two frame-header flag bytes, preserved as read. Their bit layout
  /// differs between v2.3 and v2.4, which is another reason the tag version is
  /// never rewritten.
  final int flagsHi;
  final int flagsLo;

  /// Which version's flag layout [flagsLo] follows.
  ///
  /// Required rather than defaulted, because the two layouts share no bit
  /// positions and a default would be a silent wrong answer. The flags were
  /// read with v2.4's meanings regardless of the tag's actual version, so a
  /// v2.3 compressed frame looked ordinary — `isOpaque` said false and its
  /// payload was parsed as though it were plain text.
  final int majorVersion;

  final Uint8List body;

  const Id3Frame({
    required this.id,
    required this.body,
    required this.majorVersion,
    this.flagsHi = 0,
    this.flagsLo = 0,
  });

  bool get _isV4 => majorVersion >= 4;

  // ── Frame format flags, whose bits moved between v2.3 and v2.4 ──
  bool get _isCompressed => _isV4 ? flagsLo & 0x08 != 0 : flagsLo & 0x80 != 0;
  bool get _isEncrypted => _isV4 ? flagsLo & 0x04 != 0 : flagsLo & 0x40 != 0;
  bool get _isGrouped => _isV4 ? flagsLo & 0x40 != 0 : flagsLo & 0x20 != 0;

  /// v2.4 only. v2.3 unsynchronises the whole tag or nothing.
  bool get _isUnsynchronised => _isV4 && flagsLo & 0x02 != 0;
  bool get _hasDataLengthIndicator => _isV4 && flagsLo & 0x01 != 0;

  /// True when the payload is in a form this app can't decode. Such frames are
  /// still copied through untouched — only reading them is off the table.
  bool get isOpaque => _isCompressed || _isEncrypted;

  /// The body with the per-frame wrappers peeled off, ready to parse.
  ///
  /// The extra bytes a flag adds sit in front of the data, in the order the
  /// flags are listed by the spec: group identifier, then encryption method,
  /// then the data length indicator. Encrypted frames never reach here — they
  /// are [isOpaque] — so grouping and the length indicator are what has to come
  /// off, and grouping was not being stripped at all: its one byte shifted
  /// every field of the frame by one, so the encoding byte read as part of the
  /// language and the text decoded as noise.
  Uint8List get decodedBody {
    var data = body;
    if (_isGrouped && data.isNotEmpty) {
      data = Uint8List.sublistView(data, 1);
    }
    if (_hasDataLengthIndicator && data.length >= 4) {
      data = Uint8List.sublistView(data, 4);
    }
    if (_isUnsynchronised) {
      data = Id3Tag.removeUnsynchronisation(data);
    }
    return data;
  }

  /// The same frame with the v2.4 unsynchronisation flag cleared.
  ///
  /// Used when a whole-tag pass has already removed the stuffing: leaving the
  /// flag set would say "this body is unsynchronised" over bytes that are not,
  /// so reading it back would strip $00s that were never padding — and the
  /// writer copies frames verbatim, flags included, so that claim would be
  /// written into the user's file.
  Id3Frame withoutUnsynchronisationFlag() => Id3Frame(
    id: id,
    body: body,
    majorVersion: majorVersion,
    flagsHi: flagsHi,
    flagsLo: flagsLo & ~0x02,
  );
}

/// A parsed ID3v2 tag, plus where the audio starts behind it.
class Id3Tag {
  /// 3 or 4 for tags this code can rewrite. See [isSupported].
  final int majorVersion;
  final int revision;

  /// Frames in file order, lyrics frames included.
  final List<Id3Frame> frames;

  /// Offset in the source file where the audio stream begins — past the tag and
  /// past the footer, if there was one.
  final int audioOffset;

  /// Size of the tag body declared by the header, header excluded. This is the
  /// budget an in-place rewrite has to fit inside.
  final int declaredSize;

  /// A v2.4 footer trails the tag and duplicates the header.
  final bool hadFooter;

  /// False for v2.2 and older, which use 3-character frame IDs that the walker
  /// below would misread. Such a tag must be left alone rather than rewritten
  /// from a misparse — that would drop the user's artwork.
  final bool isSupported;

  const Id3Tag({
    required this.majorVersion,
    required this.revision,
    required this.frames,
    required this.audioOffset,
    required this.declaredSize,
    required this.hadFooter,
    required this.isSupported,
  });

  /// An empty v2.4 tag, for files that arrive with no tag at all.
  factory Id3Tag.empty() => const Id3Tag(
    majorVersion: 4,
    revision: 0,
    frames: [],
    audioOffset: 0,
    declaredSize: 0,
    hadFooter: false,
    isSupported: true,
  );

  Id3Frame? frameById(String id) {
    for (final frame in frames) {
      if (frame.id == id) return frame;
    }
    return null;
  }

  /// Reads the tag at the head of [bytes], or null when there is none.
  ///
  /// Never throws on malformed input: a truncated or nonsensical tag stops the
  /// frame walk and yields whatever was read cleanly up to that point.
  static Id3Tag? parse(Uint8List bytes) {
    if (bytes.length < 10) return null;
    if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) return null;

    final major = bytes[3];
    final revision = bytes[4];
    final flags = bytes[5];
    final declaredSize = readSynchsafe(bytes, 6);

    // Per spec the declared size covers neither the header nor the footer.
    final hadFooter = major >= 4 && (flags & 0x10) != 0;
    final audioOffset = 10 + declaredSize + (hadFooter ? 10 : 0);

    if (major != 3 && major != 4) {
      return Id3Tag(
        majorVersion: major,
        revision: revision,
        frames: const [],
        audioOffset: audioOffset,
        declaredSize: declaredSize,
        hadFooter: hadFooter,
        isSupported: false,
      );
    }

    final bodyEnd = (10 + declaredSize).clamp(0, bytes.length);
    final body = Uint8List.sublistView(bytes, 10, bodyEnd);

    return Id3Tag(
      majorVersion: major,
      revision: revision,
      frames: _framesOf(
        body,
        major,
        skipExtendedHeader: flags & 0x40 != 0,
        tagUnsynchronised: flags & 0x80 != 0,
      ),
      audioOffset: audioOffset,
      declaredSize: declaredSize,
      hadFooter: hadFooter,
      isSupported: true,
    );
  }

  /// Extracts the frames, resolving v2.3's unsynchronisation ambiguity.
  ///
  /// A whole-tag unsynchronisation pass stuffs a $00 after every $FF, and v2.3
  /// never settled whether a frame's declared size counts those stuffed bytes.
  /// Both readings ship in the wild, and picking the wrong one desyncs the walk
  /// on the first affected frame — which costs the artwork.
  ///
  /// So both are tried and the one that yields more frames wins. Bodies come
  /// back de-unsynchronised either way, which is what lets the writer emit them
  /// verbatim under a header with the flag cleared.
  static List<Id3Frame> _framesOf(
    Uint8List body,
    int majorVersion, {
    required bool skipExtendedHeader,
    required bool tagUnsynchronised,
  }) {
    if (!tagUnsynchronised) {
      return _walkFrames(
        body,
        majorVersion,
        skipExtendedHeader: skipExtendedHeader,
      );
    }

    // Reading A: sizes describe the data once the stuffing is gone.
    final wholeTag = _walkFrames(
      removeUnsynchronisation(body),
      majorVersion,
      skipExtendedHeader: skipExtendedHeader,
    );

    // Reading B: sizes describe the bytes as they sit on disk.
    final perFrame = _walkFrames(
      body,
      majorVersion,
      skipExtendedHeader: skipExtendedHeader,
      unsynchroniseBodies: true,
    );

    final chosen = perFrame.length > wholeTag.length ? perFrame : wholeTag;

    // Both readings hand back de-unsynchronised bodies, so a frame that also
    // carried the v2.4 per-frame flag must stop claiming to be unsynchronised —
    // otherwise it gets de-unsynchronised a second time on the way back in, and
    // written to the file with a flag its bytes contradict.
    return [for (final frame in chosen) frame.withoutUnsynchronisationFlag()];
  }

  static List<Id3Frame> _walkFrames(
    Uint8List body,
    int majorVersion, {
    required bool skipExtendedHeader,
    bool unsynchroniseBodies = false,
  }) {
    var offset = 0;

    if (skipExtendedHeader && body.length >= 4) {
      // v2.3 states the size of what *follows* the size field; v2.4 states the
      // size of the whole extended header, itself included.
      offset += majorVersion == 3
          ? readBigEndian(body, 0) + 4
          : readSynchsafe(body, 0);
    }

    final frames = <Id3Frame>[];

    while (offset + 10 <= body.length) {
      final id = String.fromCharCodes(body, offset, offset + 4);
      if (!isFrameId(id)) break; // padding, or the tag is corrupt from here

      final size = majorVersion == 4
          ? readSynchsafe(body, offset + 4)
          : readBigEndian(body, offset + 4);

      final start = offset + 10;
      // A frame of size zero is empty, not the end of the tag. Treating it as
      // the end abandoned the walk there and lost every frame behind it — the
      // artwork included, since APIC is usually written last. Some taggers do
      // emit empty frames, and one of them should not cost the cover.
      if (size < 0 || start + size > body.length) break;

      final raw = Uint8List.sublistView(body, start, start + size);
      frames.add(
        Id3Frame(
          id: id,
          majorVersion: majorVersion,
          flagsHi: body[offset + 8],
          flagsLo: body[offset + 9],
          body: unsynchroniseBodies ? removeUnsynchronisation(raw) : raw,
        ),
      );

      offset = start + size;
    }

    return frames;
  }

  /// Builds a complete tag — header included — holding [frames] at
  /// [majorVersion].
  ///
  /// [bodySize] pins the tag body to an exact length, which is what makes an
  /// in-place rewrite possible: keeping the tag the size it already was means
  /// the audio behind it never has to move. Passing a size smaller than the
  /// frames need is a programming error and throws. Left null, the body gets
  /// [padding] bytes of slack so a later edit has room to grow into.
  static Uint8List build(
    List<Id3Frame> frames, {
    required int majorVersion,
    int revision = 0,
    int padding = 2048,
    int? bodySize,
  }) {
    final framesBytes = BytesBuilder(copy: false);
    for (final frame in frames) {
      framesBytes.add(_buildFrame(frame, majorVersion));
    }
    final framesData = framesBytes.toBytes();

    final int totalBodySize;
    if (bodySize != null) {
      if (bodySize < framesData.length) {
        throw ArgumentError.value(
          bodySize,
          'bodySize',
          'too small for ${framesData.length} bytes of frames',
        );
      }
      totalBodySize = bodySize;
    } else {
      totalBodySize = framesData.length + padding;
    }

    final out = Uint8List(10 + totalBodySize);
    out[0] = 0x49; // 'I'
    out[1] = 0x44; // 'D'
    out[2] = 0x33; // '3'
    out[3] = majorVersion;
    out[4] = revision;
    out[5] = 0; // no unsynchronisation, no extended header, no footer
    _writeSynchsafe(out, 6, totalBodySize);
    out.setRange(10, 10 + framesData.length, framesData);
    // The rest of the buffer is already zero — that is exactly what ID3
    // padding is.
    return out;
  }

  static Uint8List _buildFrame(Id3Frame frame, int majorVersion) {
    final out = Uint8List(10 + frame.body.length);
    out.setRange(0, 4, frame.id.codeUnits);
    if (majorVersion == 4) {
      _writeSynchsafe(out, 4, frame.body.length);
    } else {
      _writeBigEndian(out, 4, frame.body.length);
    }
    out[8] = frame.flagsHi;
    out[9] = frame.flagsLo;
    out.setRange(10, out.length, frame.body);
    return out;
  }

  /// Collapses the $FF $00 pairs an unsynchronisation pass inserted.
  static Uint8List removeUnsynchronisation(Uint8List data) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < data.length; i++) {
      out.addByte(data[i]);
      if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0x00) {
        i++; // swallow the stuffed null
      }
    }
    return out.toBytes();
  }

  // ── Text ──

  /// Decodes [bytes] under an ID3 [encoding] byte. Malformed input degrades to
  /// replacement characters rather than throwing — a mangled lyric beats a
  /// crash on a file the user can't easily fix.
  static String decodeText(List<int> bytes, int encoding) {
    if (bytes.isEmpty) return '';
    switch (encoding) {
      case Id3Encoding.latin1:
        return latin1.decode(bytes, allowInvalid: true);
      case Id3Encoding.utf16WithBom:
        return _decodeUtf16(bytes, bigEndian: false);
      case Id3Encoding.utf16BigEndian:
        return _decodeUtf16(bytes, bigEndian: true);
      case Id3Encoding.utf8:
      default:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static String _decodeUtf16(List<int> bytes, {required bool bigEndian}) {
    var offset = 0;
    var isBigEndian = bigEndian;

    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        isBigEndian = false;
        offset = 2;
      } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        isBigEndian = true;
        offset = 2;
      }
    }

    // Dart strings are UTF-16 internally, so surrogate pairs survive being
    // handed over as raw code units.
    final units = <int>[];
    for (var i = offset; i + 1 < bytes.length; i += 2) {
      units.add(
        isBigEndian
            ? (bytes[i] << 8) | bytes[i + 1]
            : (bytes[i + 1] << 8) | bytes[i],
      );
    }
    return String.fromCharCodes(units);
  }

  /// Encodes [text] for an ID3 [encoding] byte, terminator excluded.
  static Uint8List encodeText(String text, int encoding) {
    switch (encoding) {
      case Id3Encoding.utf16WithBom:
        final units = text.codeUnits;
        final out = Uint8List(2 + units.length * 2);
        out[0] = 0xFF; // little-endian BOM
        out[1] = 0xFE;
        var i = 2;
        for (final unit in units) {
          out[i++] = unit & 0xFF;
          out[i++] = (unit >> 8) & 0xFF;
        }
        return out;
      case Id3Encoding.latin1:
        return Uint8List.fromList(latin1.encode(text));
      case Id3Encoding.utf8:
      default:
        return Uint8List.fromList(utf8.encode(text));
    }
  }

  /// Index of the null terminator at or after [start], or -1 if there is none.
  ///
  /// UTF-16 scans in 2-byte steps, so [start] must sit on the same parity as
  /// the text field it belongs to — every ID3 field this app touches is
  /// even-aligned within its frame, which keeps that true.
  static int findTerminator(List<int> bytes, int start, int encoding) {
    if (Id3Encoding.terminatorLength(encoding) == 2) {
      for (var i = start; i + 1 < bytes.length; i += 2) {
        if (bytes[i] == 0 && bytes[i + 1] == 0) return i;
      }
      return -1;
    }
    for (var i = start; i < bytes.length; i++) {
      if (bytes[i] == 0) return i;
    }
    return -1;
  }

  // ── Integers ──

  /// Synchsafe: 7 bits per byte, so the value can never contain a $FF that a
  /// decoder would mistake for an MPEG frame sync.
  /// Public because the streaming lyrics reader walks frames itself,
  /// without ever materialising the tag. See Id3Reader.readLyricsFrames.
  static int readSynchsafe(List<int> bytes, int offset) =>
      ((bytes[offset] & 0x7F) << 21) |
      ((bytes[offset + 1] & 0x7F) << 14) |
      ((bytes[offset + 2] & 0x7F) << 7) |
      (bytes[offset + 3] & 0x7F);

  static void _writeSynchsafe(Uint8List out, int offset, int value) {
    out[offset] = (value >> 21) & 0x7F;
    out[offset + 1] = (value >> 14) & 0x7F;
    out[offset + 2] = (value >> 7) & 0x7F;
    out[offset + 3] = value & 0x7F;
  }

  static int readBigEndian(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static void _writeBigEndian(Uint8List out, int offset, int value) {
    out[offset] = (value >> 24) & 0xFF;
    out[offset + 1] = (value >> 16) & 0xFF;
    out[offset + 2] = (value >> 8) & 0xFF;
    out[offset + 3] = value & 0xFF;
  }

  static List<int> encodeBigEndian(int value) => [
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];

  /// Frame IDs are upper-case alphanumeric. Anything else means the walk has
  /// run into padding or off the rails.
  static bool isFrameId(String id) {
    if (id.length != 4) return false;
    for (var i = 0; i < 4; i++) {
      final c = id.codeUnitAt(i);
      final isDigit = c >= 0x30 && c <= 0x39;
      final isUpper = c >= 0x41 && c <= 0x5A;
      if (!isDigit && !isUpper) return false;
    }
    return true;
  }
}
