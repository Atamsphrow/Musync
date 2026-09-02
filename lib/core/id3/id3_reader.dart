import 'dart:io';
import 'dart:typed_data';

import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/lrc_parser.dart';
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

    return _withLrcRecovered(synced, unsynced);
  }

  /// Promotes a plain frame whose text is itself LRC to synchronised lyrics.
  ///
  /// This is how most taggers and several players store timings: the binary
  /// SYLT frame is patchily supported, so they ride along as `[mm:ss.xx]`
  /// prefixes inside the plain-text frame. Musync writes it that way too, next
  /// to a real SYLT, so that Musicolet and its like see the timings at all —
  /// which means Musync has to be able to read back what it writes.
  ///
  /// Without this, such a file arrived as "plain lyrics" and the brackets were
  /// shown to the user as though they were words: no highlighting, no
  /// auto-scroll, and `--:--.--` against every line in the sync editor.
  static LyricsPair _withLrcRecovered(
    SyncedLyrics? synced,
    UnsyncedLyrics? unsynced,
  ) {
    if (unsynced == null) return (synced: synced, unsynced: null);

    final recovered = LrcParser.parse(unsynced.text);
    if (recovered.isEmpty) return (synced: synced, unsynced: unsynced);

    return (
      // Only promote when there is nothing better. A real SYLT frame wins: it
      // is the frame the spec means, and Musync writes both.
      synced: synced ?? recovered,
      // Strip either way. `unsynced` means "words a person reads", and handing
      // back `[00:12.34]` under that name is a trap for whatever renders it
      // next. Stripping rather than rebuilding from `recovered` is deliberate:
      // it keeps the lines that carry no timestamp, which is where structural
      // markers live.
      unsynced: UnsyncedLyrics(LrcParser.stripTimestamps(unsynced.text)),
    );
  }

  /// Same as [readLyrics], but never loads a frame it doesn't need.
  ///
  /// [readLyrics] pulls the entire tag into memory, which for a tagged album
  /// track means the cover art — commonly 100–200 kB of it. That is fine for
  /// one file and ruinous across a whole library: the catalogue classifies
  /// every track by what lyrics it holds, so opening the app was reading
  /// hundreds of megabytes of artwork to answer a question about two frames.
  ///
  /// This walks the frame headers instead and seeks past every body except
  /// SYLT and USLT, so the cost per track is a handful of small reads rather
  /// than the size of its artwork.
  ///
  /// Tags that are unsynchronised or carry an extended header fall back to
  /// [readLyrics]: both need the whole body treated as one, and both are rare
  /// enough that a second walk isn't worth maintaining.
  static Future<LyricsPair> readLyricsFrames(String filePath) async {
    final file = File(filePath);
    RandomAccessFile? handle;

    try {
      handle = await file.open();

      final header = await handle.read(10);
      if (header.length < 10) return _noLyrics;
      if (header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) {
        return _noLyrics;
      }

      final major = header[3];
      if (major != 3 && major != 4) return _noLyrics;

      // Unsynchronisation (0x80) or an extended header (0x40).
      if (header[5] & 0xC0 != 0) {
        await handle.close();
        handle = null;
        return readLyrics(filePath);
      }

      final declaredSize = Id3Tag.readSynchsafe(header, 6);

      SyncedLyrics? synced;
      UnsyncedLyrics? unsynced;
      var walked = 0;

      while (walked + 10 <= declaredSize) {
        final frameHeader = await handle.read(10);
        if (frameHeader.length < 10) break;

        final id = String.fromCharCodes(frameHeader, 0, 4);
        // Padding, or the tag has gone off the rails. Either way, stop.
        if (!Id3Tag.isFrameId(id)) break;

        final size = major == 4
            ? Id3Tag.readSynchsafe(frameHeader, 4)
            : Id3Tag.readBigEndian(frameHeader, 4);
        // Size zero is an empty frame, not the end of the tag: stopping here
        // used to abandon every frame behind it.
        if (size < 0 || walked + 10 + size > declaredSize) break;
        walked += 10 + size;

        if (id == 'SYLT' || id == 'USLT') {
          final frame = Id3Frame(
            id: id,
            majorVersion: major,
            body: await handle.read(size),
            flagsHi: frameHeader[8],
            flagsLo: frameHeader[9],
          );
          if (frame.isOpaque) continue;
          if (id == 'SYLT') {
            synced ??= _parseSylt(frame.decodedBody);
          } else {
            unsynced ??= _parseUslt(frame.decodedBody);
          }
        } else {
          // The whole point: step over the artwork instead of reading it.
          await handle.setPosition(await handle.position() + size);
        }
      }

      return _withLrcRecovered(synced, unsynced);
    } on FileSystemException {
      return _noLyrics;
    } finally {
      await handle?.close();
    }
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

      lines.add(
        LyricLine(
          timestamp: Duration(
            milliseconds: Id3Tag.readBigEndian(body, timestampStart),
          ),
          // Line-based SYLT conventionally prefixes each line with a newline;
          // it's a separator, not part of the lyric.
          text: text.replaceAll('\r', '').replaceAll('\n', '').trim(),
        ),
      );

      offset = timestampStart + 4;
    }

    return lines.isEmpty ? null : SyncedLyrics(lines);
  }
}
