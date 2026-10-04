import 'dart:io';
import 'dart:typed_data';

import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/m4a_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';

/// Lyrics read out of a file's ID3 tag.
typedef LyricsPair = ({SyncedLyrics? synced, UnsyncedLyrics? unsynced});

const LyricsPair _noLyrics = (synced: null, unsynced: null);

/// Title, artist and album read straight out of a file's ID3 tag.
///
/// A field the tag doesn't carry is null — the caller decides the fallback.
typedef TagMetadata = ({String? title, String? artist, String? album});

const TagMetadata _noMetadata = (title: null, artist: null, album: null);

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

    final pair = readLyricsFromBytes(head);
    if (pair.synced != null || pair.unsynced != null) return pair;

    // No embedded lyrics — maybe an M4A with ©lyr.
    final m4a = await _readM4aLyrics(filePath);
    if (m4a.synced != null || m4a.unsynced != null) return m4a;

    // Still nothing — maybe a sidecar .lrc next to the audio file.
    // Musicolet writes these instead of embedding ("Embedded Lyrics + LRC
    // support"): without this, its edits are invisible to Musync.
    return _readSidecarLrc(filePath);
  }

  /// Reads `<basename>.lrc` next to the audio file, if present.
  ///
  /// Returns "no lyrics" when there is no sidecar, it can't be read, or it
  /// holds no usable lines — the caller then reports "no lyrics" as before.
  static Future<LyricsPair> _readSidecarLrc(String filePath) async {
    final dot = filePath.lastIndexOf('.');
    if (dot < 0) return _noLyrics;
    final lrcPath = '${filePath.substring(0, dot)}.lrc';
    final lrcFile = File(lrcPath);
    try {
      if (!await lrcFile.exists()) return _noLyrics;
      final text = await lrcFile.readAsString();
      if (text.trim().isEmpty) return _noLyrics;
      final synced = LrcParser.parse(text);
      if (synced.isNotEmpty) return (synced: synced, unsynced: null);
      // Plain text without timestamps: still lyrics, just not synced.
      final plain = LrcParser.stripTimestamps(text).trim();
      if (plain.isEmpty) return _noLyrics;
      return (synced: null, unsynced: UnsyncedLyrics(plain));
    } catch (_) {
      return _noLyrics;
    }
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
  /// Reads lyrics from an M4A's ©lyr atom.
  static Future<LyricsPair> _readM4aLyrics(String filePath) async {
    final lrc = await M4aWriter.readLrc(filePath);
    if (lrc == null || lrc.trim().isEmpty) return _noLyrics;
    final hasTs = lrc.split('\n').any(
        (line) => LrcParser.leadingTimestamps(line).isNotEmpty);
    if (hasTs) {
      try {
        final synced = LrcParser.parse(lrc);
        return (synced: synced, unsynced: null);
      } catch (_) {}
    }
    return (synced: null, unsynced: UnsyncedLyrics(lrc));
  }

  static Future<LyricsPair> readLyricsFrames(String filePath) async {
    final file = File(filePath);
    RandomAccessFile? handle;

    try {
      handle = await file.open();

      final header = await handle.read(10);
      if (header.length < 10) return _noLyrics;
      if (header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) {
        // Not ID3 — maybe an M4A with lyrics in ©lyr.
        await handle.close();
        handle = null;
        final m4a = await _readM4aLyrics(filePath);
        if (m4a.synced != null || m4a.unsynced != null) return m4a;
        // Still nothing — maybe a sidecar .lrc (Musicolet writes these).
        return await _readSidecarLrc(filePath);
      }

      final major = header[3];
      if (major != 3 && major != 4) return _noLyrics;

      // Unsynchronisation (0x80) or an extended header (0x40).
      if (header[5] & 0xC0 != 0) {
        await handle.close();
        handle = null;
        return await readLyrics(filePath);
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

      final pair = _withLrcRecovered(synced, unsynced);
      if (pair.synced != null || pair.unsynced != null) return pair;
      // No embedded lyrics — maybe a sidecar .lrc (Musicolet writes these).
      await handle.close();
      handle = null;
      return await _readSidecarLrc(filePath);
    } on FileSystemException {
      return _noLyrics;
    } finally {
      await handle?.close();
    }
  }

  /// Basic metadata (title, artist, album) read straight out of a file's ID3
  /// tag, bypassing MediaStore.
  ///
  /// MediaStore caches metadata on Android's own schedule, so a tag edited by
  /// another app stays invisible to a plain re-query until the system rescans.
  /// This walks the tag's frame headers and reads only TIT2/TPE1/TALB,
  /// stepping over everything else — cover art included — so a library-wide
  /// refresh doesn't pull hundreds of megabytes of artwork into memory.
  ///
  /// A field the tag doesn't carry comes back null and the caller keeps its
  /// previous value; an unreadable file yields all nulls, never an exception.
  static Future<TagMetadata> readMetadata(String filePath) async {
    final file = File(filePath);
    bool exists;
    try {
      exists = await file.exists();
    } on FileSystemException {
      return _noMetadata;
    }
    if (!exists) return _noMetadata;

    final frames = await _readTextFrames(
      filePath,
      const {'TIT2', 'TPE1', 'TALB'},
    );
    return (title: frames['TIT2'], artist: frames['TPE1'], album: frames['TALB']);
  }

  /// Same as [readMetadata], against bytes already in memory.
  static TagMetadata readMetadataFromBytes(Uint8List bytes) {
    final tag = Id3Tag.parse(bytes);
    if (tag == null || !tag.isSupported) return _noMetadata;

    String? title;
    String? artist;
    String? album;
    for (final frame in tag.frames) {
      if (frame.isOpaque) continue;
      switch (frame.id) {
        case 'TIT2':
          title ??= _parseTextFrame(frame.decodedBody);
        case 'TPE1':
          artist ??= _parseTextFrame(frame.decodedBody);
        case 'TALB':
          album ??= _parseTextFrame(frame.decodedBody);
      }
      if (title != null && artist != null && album != null) break;
    }
    return (title: title, artist: artist, album: album);
  }

  /// Reads the decoded text of [wanted] text frames, walking the tag without
  /// loading anything else.
  ///
  /// The metadata twin of [readLyricsFrames]: the same frame walk,
  /// parameterised by frame ID, so the artwork (and every other unneeded
  /// frame) is stepped over rather than read. The first occurrence of each ID
  /// wins.
  static Future<Map<String, String>> _readTextFrames(
    String filePath,
    Set<String> wanted,
  ) async {
    final found = <String, String>{};
    final file = File(filePath);
    RandomAccessFile? handle;

    try {
      handle = await file.open();

      final header = await handle.read(10);
      if (header.length < 10) return found;
      if (header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) {
        return found;
      }

      final major = header[3];
      if (major != 3 && major != 4) return found;

      // Unsynchronisation (0x80) or an extended header (0x40). Rare enough
      // that the whole-tag parse is the sane fallback — the same call
      // [readLyricsFrames] makes.
      if (header[5] & 0xC0 != 0) {
        await handle.close();
        handle = null;
        return await _readTextFramesFallback(file, wanted);
      }

      final declaredSize = Id3Tag.readSynchsafe(header, 6);

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
        if (size < 0 || walked + 10 + size > declaredSize) break;
        walked += 10 + size;

        if (wanted.contains(id) && !found.containsKey(id)) {
          final frame = Id3Frame(
            id: id,
            majorVersion: major,
            body: await handle.read(size),
            flagsHi: frameHeader[8],
            flagsLo: frameHeader[9],
          );
          if (frame.isOpaque) continue;
          final text = _parseTextFrame(frame.decodedBody);
          if (text != null) found[id] = text;
        } else {
          // The whole point: step over the artwork instead of reading it.
          await handle.setPosition(await handle.position() + size);
        }
      }

      return found;
    } on FileSystemException {
      return found;
    } finally {
      await handle?.close();
    }
  }

  /// Whole-tag fallback for the rare tags [_readTextFrames] won't walk
  /// (unsynchronised, extended header).
  static Future<Map<String, String>> _readTextFramesFallback(
    File file,
    Set<String> wanted,
  ) async {
    final found = <String, String>{};
    final Uint8List head;
    try {
      head = await _readHead(file);
    } on FileSystemException {
      return found;
    }
    final tag = Id3Tag.parse(head);
    if (tag == null || !tag.isSupported) return found;
    for (final frame in tag.frames) {
      if (frame.isOpaque) continue;
      if (wanted.contains(frame.id) && !found.containsKey(frame.id)) {
        final text = _parseTextFrame(frame.decodedBody);
        if (text != null) found[frame.id] = text;
      }
    }
    return found;
  }

  /// A text frame body: one encoding byte, then the text. Stops at the first
  /// terminator — a second value (another artist, say) is a display question,
  /// not a read question.
  static String? _parseTextFrame(Uint8List body) {
    if (body.isEmpty) return null;
    final encoding = body[0];
    final end = Id3Tag.findTerminator(body, 1, encoding);
    final slice = end == -1
        ? Uint8List.sublistView(body, 1)
        : Uint8List.sublistView(body, 1, end);
    final text = Id3Tag.decodeText(slice, encoding).trim();
    return text.isEmpty ? null : text;
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
