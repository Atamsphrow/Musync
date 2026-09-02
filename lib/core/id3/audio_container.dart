/// Which container a file actually is, read from its own first bytes.
///
/// This exists because of a file-destroying bug. `Id3Tag.parse` recognises a
/// tag by the letters `ID3` at offset 0 and returns null for anything else —
/// including an M4A, which opens with an `ftyp` atom. The writer read that null
/// as "this file simply has no tag yet" and went on to *prepend* a fresh ID3v2
/// tag to an MP4 container.
///
/// MP4 stores every atom offset as an absolute position from the start of the
/// file. Pushing the whole container down by a few kilobytes invalidates the
/// sample tables in `moov`, and the track stops playing. Silently: the user was
/// told the lyrics had been saved.
///
/// So the format is now named before anything is written, and a container
/// Musync does not know how to edit is refused out loud.
library;

import 'dart:typed_data';

enum AudioContainer {
  /// The only one Musync can write to. ID3v2 sits in front of the audio, and
  /// nothing inside the stream refers to absolute file offsets.
  mp3,

  /// MP4 / M4A / AAC. Atom offsets are absolute, so a tag cannot be bolted on
  /// the front.
  mp4,

  flac,
  ogg,
  wav,

  /// Nothing recognised. Deliberately *not* refused — see
  /// [AudioContainerCheck.isWritable].
  unknown,
}

extension AudioContainerCheck on AudioContainer {
  /// Whether Musync may rewrite this file's tags.
  ///
  /// `unknown` is allowed through on purpose. MP3 writing is proven — the
  /// real-file probe checks four of them byte for byte — and an MP3 with junk
  /// before its first frame would land here. Refusing everything unidentified
  /// would trade a known bug for an unknown regression; the bug being fixed is
  /// specifically that recognisable non-MP3 containers were treated as MP3.
  bool get isWritable =>
      this == AudioContainer.mp3 || this == AudioContainer.unknown;

  /// Name for a message to the user.
  String get label => switch (this) {
    AudioContainer.mp3 => 'MP3',
    AudioContainer.mp4 => 'MP4 / M4A',
    AudioContainer.flac => 'FLAC',
    AudioContainer.ogg => 'Ogg',
    AudioContainer.wav => 'WAV',
    AudioContainer.unknown => 'inconnu',
  };
}

abstract final class AudioContainerReader {
  /// Enough bytes to see every magic number below.
  static const int headerBytes = 16;

  /// Identifies [head], the first bytes of a file.
  ///
  /// Reads the file's own content rather than trusting its extension: a `.mp3`
  /// that is really an M4A is exactly the case that corrupts, and the
  /// extension is the one thing a user can rename by accident.
  static AudioContainer detect(Uint8List head) {
    if (head.length < 4) return AudioContainer.unknown;

    // 'ID3' — an ID3v2 tag. In practice always MP3; the standard permits it
    // elsewhere, but no container Musync meets uses it.
    if (_matches(head, 0, 'ID3')) return AudioContainer.mp3;

    // MPEG audio frame sync: eleven set bits. An MP3 with no tag at all.
    if (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) return AudioContainer.mp3;

    // 'ftyp' sits at offset 4, after the atom's own size field.
    if (head.length >= 8 && _matches(head, 4, 'ftyp')) {
      return AudioContainer.mp4;
    }

    if (_matches(head, 0, 'fLaC')) return AudioContainer.flac;
    if (_matches(head, 0, 'OggS')) return AudioContainer.ogg;
    if (head.length >= 12 &&
        _matches(head, 0, 'RIFF') &&
        _matches(head, 8, 'WAVE')) {
      return AudioContainer.wav;
    }

    return AudioContainer.unknown;
  }

  static bool _matches(Uint8List bytes, int offset, String ascii) {
    if (offset + ascii.length > bytes.length) return false;
    for (var i = 0; i < ascii.length; i++) {
      if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
    }
    return true;
  }
}
