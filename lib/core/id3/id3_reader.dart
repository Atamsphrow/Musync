import 'dart:io';
import 'dart:typed_data';

import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/models/lyrics.dart';

/// Lyrics read out of a file's ID3 tag.
typedef LyricsPair = ({SyncedLyrics? synced, UnsyncedLyrics? unsynced});

const LyricsPair _noLyrics = (synced: null, unsynced: null);

/// Reads USLT (plain) and SYLT (synchronised) lyrics frames.
///
/// Anything unreadable — no tag, a version this app won't touch, a corrupt
/// frame — comes back as "no lyrics" rather than an exception. A song that
/// can't yield lyrics still has to play.
class Id3Reader {
  const Id3Reader._();

  static Future<LyricsPair> readLyrics(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return _noLyrics;

    // The tag lives at the head of the file, so reading the first chunk is
    // enough — no reason to pull a 10 MB track into memory for its lyrics.
    final Uint8List head;
    try {
      head = await _readHead(file);
    } on FileSystemException {
      return _noLyrics;
    }

    return readLyricsFromBytes(head);
  }

  /// Same as [readLyrics], against bytes already in memory.
  static LyricsPair readLyricsFromBytes(Uint8List bytes) {
    final tag = Id3Tag.parse(bytes);
    if (tag == null || !tag.isSupported) return _noLyrics;

    SyncedLyrics? synced;
    UnsyncedLyrics? unsynced;

    for (final frame in tag.frames) {
      if (frame.isOpaque) continue;
      if (frame.id == 'SYLT') {
        synced ??= _parseSylt(frame.decodedBody);
      } else if (frame.id == 'USLT') {
        unsynced ??= _parseUslt(frame.decodedBody);
      }
    }

    return (synced: synced, unsynced: unsynced);
  }

  /// Reads enough of the file to cover the whole tag.
  ///
  /// The header states the tag's length, so this takes two passes: 10 bytes to
  /// learn the size, then the tag itself.
  static Future<Uint8List> _readHead(File file) async {
    final handle = await file.open();
    try {
      final header = await handle.read(10);
      if (header.length < 10) return header;

      final tag = Id3Tag.parse(header);
      if (tag == null) return header;

      await handle.setPosition(0);
      return await handle.read(tag.audioOffset);
    } finally {
      await handle.close();
    }
  }

  /// USLT: encoding, 3-byte language, descriptor, terminator, then the text.
  static UnsyncedLyrics? _parseUslt(Uint8List body) {
    if (body.length < 5) return null;

    final encoding = body[0];
    final descriptorEnd = Id3Tag.findTerminator(body, 4, encoding);
    if (descriptorEnd == -1) return null;

    final textStart = descriptorEnd + Id3Encoding.terminatorLength(encoding);
    if (textStart >= body.length) return null;

    final text = Id3Tag.decodeText(
      Uint8List.sublistView(body, textStart),
      encoding,
    );
    return text.trim().isEmpty ? null : UnsyncedLyrics(text);
  }

  /// SYLT: encoding, 3-byte language, timestamp format, content type,
  /// descriptor, terminator, then repeating `<text><terminator><timestamp>`.
  static SyncedLyrics? _parseSylt(Uint8List body) {
    if (body.length < 7) return null;

    final encoding = body[0];
    final timestampFormat = body[4];

    // Format 1 counts MPEG frames, which can't be converted to a duration
    // without decoding the audio. Musync only ever writes format 2.
    if (timestampFormat != 2) return null;

    final descriptorEnd = Id3Tag.findTerminator(body, 6, encoding);
    if (descriptorEnd == -1) return null;

    var offset = descriptorEnd + Id3Encoding.terminatorLength(encoding);
    final terminatorLength = Id3Encoding.terminatorLength(encoding);
    final lines = <LyricLine>[];

    while (offset + terminatorLength + 4 <= body.length) {
      final textEnd = Id3Tag.findTerminator(body, offset, encoding);
      if (textEnd == -1) break;

      final text = Id3Tag.decodeText(
        Uint8List.sublistView(body, offset, textEnd),
        encoding,
      );

      final timestampStart = textEnd + terminatorLength;
      if (timestampStart + 4 > body.length) break;

      lines.add(LyricLine(
        timestamp: Duration(
          milliseconds: Id3Tag.readBigEndian(body, timestampStart),
        ),
        // Line-based SYLT conventionally prefixes each line with a newline;
        // it's a separator, not part of the lyric.
        text: text.replaceAll('\r', '').replaceAll('\n', '').trim(),
      ));

      offset = timestampStart + 4;
    }

    return lines.isEmpty ? null : SyncedLyrics(lines);
  }
}
