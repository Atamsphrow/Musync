import 'dart:io';
import 'dart:typed_data';

import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/models/lyrics.dart';

/// Raised when lyrics can't be written. Carries a message meant to be shown to
/// the user, since every cause here is something only they can act on: a file
/// the app isn't allowed to touch, or a tag format it won't risk rewriting.
class Id3WriteException implements Exception {
  final String message;
  final Object? cause;

  const Id3WriteException(this.message, [this.cause]);

  @override
  String toString() => 'Id3WriteException: $message';
}

/// Writes USLT (plain) and SYLT (synchronised) lyrics into an MP3's ID3 tag.
///
/// Every other frame is carried across untouched, and the tag keeps its
/// original major version — see `id3_tag.dart` for why that matters.
class Id3Writer {
  const Id3Writer._();

  /// ISO-639-2 code stored in the lyrics frames. The API takes a language but
  /// nothing in Musync surfaces it, and 'eng' is what every tagger defaults to.
  static const List<int> _language = [0x65, 0x6E, 0x67]; // 'eng'

  /// Slack left after the frames on a full rewrite, so the next few edits can
  /// grow into the existing tag instead of moving the audio again.
  static const int _padding = 4096;

  /// Replaces the lyrics frames of [filePath].
  ///
  /// Passing null (or empty) for both removes any lyrics already there.
  /// Throws [Id3WriteException] if the file can't be written.
  static Future<void> writeLyrics(
    String filePath, {
    SyncedLyrics? synced,
    UnsyncedLyrics? unsynced,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Id3WriteException('Fichier introuvable : $filePath');
    }

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException catch (e) {
      throw Id3WriteException('Lecture impossible : ${e.osError?.message ?? e.message}', e);
    }

    final tag = Id3Tag.parse(bytes) ?? Id3Tag.empty();
    if (!tag.isSupported) {
      throw Id3WriteException(
        'Tag ID3v2.${tag.majorVersion} non pris en charge. Réencoder le fichier '
        'en ID3v2.3 ou v2.4 avant d\'ajouter des paroles.',
      );
    }

    final frames = <Id3Frame>[
      // Keep everything that isn't lyrics, in its original order.
      for (final frame in tag.frames)
        if (frame.id != 'SYLT' && frame.id != 'USLT') frame,
      if (synced != null && synced.isNotEmpty)
        _buildSyltFrame(synced, tag.majorVersion),
      if (unsynced != null && unsynced.isNotEmpty)
        _buildUsltFrame(unsynced, tag.majorVersion),
    ];

    final framesSize = frames.fold<int>(0, (sum, f) => sum + 10 + f.body.length);

    // Fast path: the new tag fits where the old one sat, so the audio — which
    // is all but a few kilobytes of the file — never has to be rewritten. This
    // is what keeps repeated saves in the sync editor instant.
    final fitsInPlace = tag.audioOffset > 0 &&
        !tag.hadFooter &&
        framesSize <= tag.declaredSize;

    final newTag = Id3Tag.build(
      frames,
      majorVersion: tag.majorVersion,
      revision: tag.revision,
      bodySize: fitsInPlace ? tag.declaredSize : null,
      padding: _padding,
    );

    try {
      if (fitsInPlace) {
        await _overwriteHead(file, newTag);
      } else {
        await _rewriteFile(file, newTag, bytes, tag.audioOffset);
      }
    } on FileSystemException catch (e) {
      throw Id3WriteException(_describeWriteFailure(e), e);
    }
  }

  /// Overwrites the tag region without touching the audio behind it.
  static Future<void> _overwriteHead(File file, Uint8List newTag) async {
    // FileMode.append is the only writable mode that doesn't truncate.
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.setPosition(0);
      await handle.writeFrom(newTag);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  /// Writes tag + audio to a sibling temp file, then swaps it in.
  ///
  /// Going via a temp file means an interrupted write leaves the original
  /// intact rather than a half-written track.
  static Future<void> _rewriteFile(
    File file,
    Uint8List newTag,
    Uint8List original,
    int audioOffset,
  ) async {
    final temp = File('${file.path}.musync.tmp');
    try {
      final handle = await temp.open(mode: FileMode.write);
      try {
        await handle.writeFrom(newTag);
        await handle.writeFrom(original, audioOffset);
        await handle.flush();
      } finally {
        await handle.close();
      }
      await temp.rename(file.path);
    } catch (_) {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // Best effort — the original is untouched either way.
        }
      }
      rethrow;
    }
  }

  static String _describeWriteFailure(FileSystemException e) {
    // errno 13 (EACCES) / 1 (EPERM) is what scoped storage returns for a file
    // the app has read access to but no write grant on.
    final errno = e.osError?.errorCode;
    if (errno == 13 || errno == 1) {
      return 'Écriture refusée par Android. Autoriser l\'accès aux fichiers '
          'pour que Musync puisse modifier les tags.';
    }
    return 'Écriture impossible : ${e.osError?.message ?? e.message}';
  }

  // ── Frame construction ──

  /// SYLT: encoding, language, timestamp format, content type, empty
  /// descriptor, then `<text><terminator><timestamp>` per line.
  static Id3Frame _buildSyltFrame(SyncedLyrics lyrics, int majorVersion) {
    final encoding = Id3Encoding.unicodeFor(majorVersion);
    final terminator = List<int>.filled(
      Id3Encoding.terminatorLength(encoding),
      0,
    );

    final body = BytesBuilder(copy: false)
      ..addByte(encoding)
      ..add(_language)
      ..addByte(2) // timestamps in milliseconds
      ..addByte(1) // content type: lyrics
      ..add(terminator); // empty content descriptor

    for (final line in lyrics.lines) {
      body
        ..add(Id3Tag.encodeText(line.text, encoding))
        ..add(terminator)
        ..add(Id3Tag.encodeBigEndian(
          line.timestamp.inMilliseconds.clamp(0, 0x7FFFFFFF),
        ));
    }

    return Id3Frame(id: 'SYLT', body: body.toBytes());
  }

  /// USLT: encoding, language, empty descriptor, then the whole text.
  static Id3Frame _buildUsltFrame(UnsyncedLyrics lyrics, int majorVersion) {
    final encoding = Id3Encoding.unicodeFor(majorVersion);
    final body = BytesBuilder(copy: false)
      ..addByte(encoding)
      ..add(_language)
      ..add(List<int>.filled(Id3Encoding.terminatorLength(encoding), 0))
      ..add(Id3Tag.encodeText(lyrics.text, encoding));

    return Id3Frame(id: 'USLT', body: body.toBytes());
  }
}
