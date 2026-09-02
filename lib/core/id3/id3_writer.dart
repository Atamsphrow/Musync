import 'dart:io';
import 'dart:typed_data';

import 'package:musync/core/id3/audio_container.dart';
import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/lrc_parser.dart';
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
      throw Id3WriteException(
        'Lecture impossible : ${e.osError?.message ?? e.message}',
        e,
      );
    }

    // The format is named before a single byte is written.
    //
    // Without this, an M4A took the "no tag yet" path below and had an ID3v2
    // tag prepended to it — which moves every byte of an MP4 container down and
    // invalidates the absolute atom offsets inside `moov`. The track stopped
    // playing, and Musync said the lyrics had been saved.
    //
    // Refusing is the honest answer, not a limitation to be worked around:
    // there is no standard way to carry synchronised lyrics in MP4 at all, so
    // even a correct writer could only ever store plain text there.
    final container = AudioContainerReader.detect(bytes);
    if (!container.isWritable) {
      throw Id3WriteException(
        'Musync ne sait écrire les paroles que dans des fichiers MP3. '
        'Celui-ci est un fichier ${container.label}, et y écrire l\'abîmerait.',
      );
    }

    final tag = Id3Tag.parse(bytes) ?? Id3Tag.empty();
    if (!tag.isSupported) {
      throw Id3WriteException(
        'Tag ID3v2.${tag.majorVersion} non pris en charge. Réencoder le fichier '
        'en ID3v2.3 ou v2.4 avant d\'ajouter des paroles.',
      );
    }

    // The plain frame carries the timings too, as LRC text.
    //
    // SYLT is the frame the spec intends for this, and it is written below —
    // but support for it is patchy, and Musicolet is one of the players that
    // ignores it and reads `[mm:ss.xx]` prefixes out of the plain frame
    // instead. A track written with SYLT alone showed up there as ordinary
    // unsynchronised lyrics. Writing both costs a few hundred bytes and is what
    // makes the timings visible outside Musync.
    //
    // The caller's own text is kept only when it already carries the timings.
    //
    // The sync editor's does: it emits LRC as soon as anything is timed, and
    // its version is worth preferring because it also holds the lines the user
    // deliberately left untimed — `[Refrain]` and friends — which SyncedLyrics
    // does not carry and which deriving from it would silently drop.
    //
    // The search screen's does not. LRCLIB hands back the timed lyric and a
    // plain transcription side by side, and passing the plain one straight
    // through wrote a USLT with no timings in it at all — so a track fetched
    // online still showed up unsynchronised in Musicolet, which is the whole
    // failure this is meant to fix. Trusting the caller unconditionally was the
    // wrong contract; the guarantee belongs here, at the one place that writes.
    final plain = _plainFrameFor(synced, unsynced);

    final frames = <Id3Frame>[
      // Keep everything that isn't lyrics, in its original order.
      for (final frame in tag.frames)
        if (frame.id != 'SYLT' && frame.id != 'USLT') frame,
      if (synced != null && synced.isNotEmpty)
        _buildSyltFrame(synced, tag.majorVersion),
      if (plain != null && plain.isNotEmpty)
        _buildUsltFrame(plain, tag.majorVersion),
    ];

    final framesSize = frames.fold<int>(
      0,
      (sum, f) => sum + 10 + f.body.length,
    );

    // Fast path: the new tag fits where the old one sat, so the audio — which
    // is all but a few kilobytes of the file — never has to be rewritten. This
    // is what keeps repeated saves in the sync editor instant.
    final fitsInPlace =
        tag.audioOffset > 0 && !tag.hadFooter && framesSize <= tag.declaredSize;

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

  /// Turns an OS error into something the user can act on.
  ///
  /// Every one of these is a situation only they can resolve, and the raw
  /// message ("Errno = 28") tells them nothing about which. Naming the cause is
  /// the difference between "the app is broken" and "the phone is full".
  static String _describeWriteFailure(FileSystemException e) {
    return switch (e.osError?.errorCode) {
      // Scoped storage's answer for a file the app can read but has no write
      // grant on — by far the most common failure here.
      13 || 1 =>
        'Écriture refusée par Android. Autorisez l\'accès à tous les fichiers '
            'pour que Musync puisse modifier les tags.',

      // ENOSPC. The rewrite path needs room for a second copy of the track
      // before the rename swaps it in, so this can happen on a phone that still
      // looks like it has a little space left.
      28 =>
        'Espace insuffisant sur l\'appareil. L\'enregistrement écrit une copie '
            'temporaire du morceau avant de la substituer à l\'original, il '
            'faut donc brièvement deux fois sa taille.',

      // EROFS — an SD card mounted read-only, usually.
      30 =>
        'Ce support est en lecture seule. Le fichier ne peut pas être modifié '
            'là où il se trouve.',

      // ETXTBSY / EBUSY.
      16 || 26 =>
        'Le fichier est utilisé par une autre application. Fermez-la et '
            'réessayez.',

      // ENOENT, between the existence check and the write.
      2 =>
        'Le fichier a disparu pendant l\'enregistrement. Relancez l\'analyse '
            'de la bibliothèque.',

      _ => 'Écriture impossible : ${e.osError?.message ?? e.message}',
    };
  }

  /// Decides what goes into the plain frame.
  ///
  /// The rule, in one line: whenever there are timings, the plain frame carries
  /// them. Whether that text comes from the caller or is derived here depends
  /// only on whether the caller's already has them.
  ///
  /// The LRC test mirrors the one [Id3Reader] applies on the way back in, which
  /// is what keeps writing and reading symmetrical — a file Musync writes is a
  /// file Musync reads back the same way.
  static UnsyncedLyrics? _plainFrameFor(
    SyncedLyrics? synced,
    UnsyncedLyrics? unsynced,
  ) {
    if (synced == null || synced.isEmpty) return unsynced;
    if (unsynced == null || unsynced.isEmpty) {
      return UnsyncedLyrics(synced.toLrc());
    }

    final alreadyTimed = LrcParser.parse(unsynced.text).isNotEmpty;
    return alreadyTimed ? unsynced : UnsyncedLyrics(synced.toLrc());
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
        // The leading newline is what marks a syllable as starting a new line.
        // SYLT carries no other notion of line breaks, so without it a player
        // sees one unbroken run of syllables: Musicolet fell back to the plain
        // USLT text and showed the track as unsynchronised, even though the
        // timings were right there. Id3Reader already strips this on the way
        // back in — the writer simply never emitted it.
        ..add(Id3Tag.encodeText('\n${line.text}', encoding))
        ..add(terminator)
        // Non-null by construction: SyncedLyrics drops untimed lines on the way
        // in, which is how a `[Refrain]` marker stays in USLT without ever
        // becoming a SYLT entry.
        ..add(
          Id3Tag.encodeBigEndian(
            line.timestamp!.inMilliseconds.clamp(0, 0x7FFFFFFF),
          ),
        );
    }

    return Id3Frame(
      id: 'SYLT',
      body: body.toBytes(),
      majorVersion: majorVersion,
    );
  }

  /// USLT: encoding, language, empty descriptor, then the whole text.
  static Id3Frame _buildUsltFrame(UnsyncedLyrics lyrics, int majorVersion) {
    final encoding = Id3Encoding.unicodeFor(majorVersion);
    final body = BytesBuilder(copy: false)
      ..addByte(encoding)
      ..add(_language)
      ..add(List<int>.filled(Id3Encoding.terminatorLength(encoding), 0))
      ..add(Id3Tag.encodeText(lyrics.text, encoding));

    return Id3Frame(
      id: 'USLT',
      body: body.toBytes(),
      majorVersion: majorVersion,
    );
  }
}
