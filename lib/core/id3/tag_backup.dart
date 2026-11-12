/// Keeps the previous tag of every track Musync writes, so a write can be undone.
///
/// The app's one destructive act is rewriting a tag inside the user's own music.
/// The writer is careful and the probe proves the audio survives byte for byte —
/// but *correct* is not *wanted*, and a lyric matched to the wrong track is
/// today unrecoverable. This is the way back.
///
/// Only the tag is kept, never the audio: a tag is a few hundred kilobytes even
/// with cover art, where the track is several megabytes. Restoring means putting
/// the old tag back in front of the audio that is there now — which is sound
/// precisely because the audio never moves.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:musync/core/id3/audio_container.dart';
import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/m4a_writer.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:path_provider/path_provider.dart';

/// One recorded write.
@immutable
class TagBackup {
  /// The track this belongs to.
  final String filePath;

  /// When Musync wrote to it.
  final DateTime writtenAt;

  /// Size of the stored tag, for the list and for the size cap.
  final int tagBytes;

  /// The track's modification time just after Musync wrote it.
  ///
  /// Restoring checks this. If the file has moved on since — another tagger,
  /// another app — putting an old tag back would undo their work as well as
  /// ours, and the user should be told rather than surprised.
  final int writtenMtime;

  /// Name of the file holding the bytes, inside the backup directory.
  final String storedAs;

  /// Name of the file holding the sidecar `.lrc` bytes, when the track
  /// had one at capture time — null otherwise. A sidecar is another
  /// app's file (Musicolet), never Musync's own writing: the backup
  /// only matters when Musync deletes it, which only the
  /// « Paroles incorrectes » tap does. Any other caller that restores
  /// finds the sidecar still there and leaves it alone.
  final String? sidecarStoredAs;

  /// The sidecar's exact path at capture time, extension included
  /// (`.lrc` or `.LRC`) — where the bytes go back on a restore.
  final String? sidecarPath;

  const TagBackup({
    required this.filePath,
    required this.writtenAt,
    required this.tagBytes,
    required this.writtenMtime,
    required this.storedAs,
    this.sidecarStoredAs,
    this.sidecarPath,
  });

  /// Just the track's file name, for a list on a phone.
  String get displayName {
    final cut = filePath.lastIndexOf(RegExp(r'[/\\]'));
    return cut < 0 ? filePath : filePath.substring(cut + 1);
  }

  Map<String, Object?> toJson() => {
    'filePath': filePath,
    'writtenAt': writtenAt.toIso8601String(),
    'tagBytes': tagBytes,
    'writtenMtime': writtenMtime,
    'storedAs': storedAs,
    if (sidecarStoredAs != null) 'sidecarStoredAs': sidecarStoredAs,
    if (sidecarPath != null) 'sidecarPath': sidecarPath,
  };

  static TagBackup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['filePath'];
    final storedAs = raw['storedAs'];
    final writtenAt = DateTime.tryParse('${raw['writtenAt']}');
    if (path is! String || storedAs is! String || writtenAt == null) {
      return null;
    }

    return TagBackup(
      filePath: path,
      writtenAt: writtenAt,
      tagBytes: raw['tagBytes'] is int ? raw['tagBytes'] as int : 0,
      writtenMtime: raw['writtenMtime'] is int ? raw['writtenMtime'] as int : 0,
      storedAs: storedAs,
      // Added later: an older index simply has neither.
      sidecarStoredAs: raw['sidecarStoredAs'] is String
          ? raw['sidecarStoredAs'] as String
          : null,
      sidecarPath: raw['sidecarPath'] is String
          ? raw['sidecarPath'] as String
          : null,
    );
  }
}

/// Why a restore could not go ahead.
class TagRestoreException implements Exception {
  final String message;

  const TagRestoreException(this.message);

  @override
  String toString() => 'TagRestoreException: $message';
}

/// Stores and restores tags.
///
/// One backup per track: undoing means going back to the state before the most
/// recent write, which is what the word means to anyone who presses it. Writing
/// twice and undoing once steps back one write, not both.
class TagBackupStore {
  /// Overridable so tests do not need `path_provider`.
  final Directory? root;

  TagBackupStore({this.root});

  static const String _indexName = 'index.json';

  /// Ceilings on what this may occupy.
  ///
  /// A tag with 3.6 MB of cover art is not unusual in this library, so a plain
  /// count would be a poor bound on its own. Whichever limit bites first wins,
  /// and the oldest entries go.
  static const int _maxEntries = 100;

  /// How many steps back one track can walk. Each write keeps its own copy, so
  /// undoing twice goes two writes back; the oldest is dropped past this.
  static const int _maxPerFile = 10;
  static const int _maxTotalBytes = 64 * 1024 * 1024;

  /// Cached so the directory is only created once per store.
  Directory? _resolved;

  Future<Directory> _dir() async {
    if (_resolved != null) return _resolved!;
    final base = root ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}tag_backups');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _resolved = dir;
  }

  Future<File> _indexFile() async =>
      File('${(await _dir()).path}${Platform.pathSeparator}$_indexName');

  /// Newest first.
  Future<List<TagBackup>> list() async {
    try {
      final file = await _indexFile();
      if (!await file.exists()) return const [];

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];

      final entries = [for (final e in decoded) ?TagBackup.fromJson(e)];
      // Newest first. `sort` is not stable, and the stored name carries the
      // microsecond of its capture, which settles a tie.
      entries.sort((a, b) {
        final byTime = b.writtenAt.compareTo(a.writtenAt);
        return byTime != 0 ? byTime : b.storedAs.compareTo(a.storedAs);
      });
      return entries;
    } catch (error, stack) {
      // An empty list here reads to the user as "there is nothing to undo",
      // which is indistinguishable from "the index is unreadable and your whole
      // undo history is unreachable". Those are very different, and only one of
      // them is worth telling someone about.
      DebugLog.instance.error(
        'Sauvegarde',
        'Historique des sauvegardes illisible : rien ne sera proposé à annuler',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  Future<void> _writeIndex(List<TagBackup> entries) async {
    await AtomicFile.writeString(
      await _indexFile(),
      jsonEncode([for (final e in entries) e.toJson()]),
    );
  }

  /// Whether [filePath] has something to go back to.
  Future<TagBackup?> backupFor(String filePath) async {
    for (final entry in await list()) {
      if (entry.filePath == filePath) return entry;
    }
    return null;
  }

  /// Records the tag currently on [filePath]. Call *before* writing.
  ///
  /// Failure is swallowed and reported as false: a backup that cannot be taken
  /// must not stop the user embedding lyrics. Losing the ability to undo is a
  /// smaller harm than refusing to work at all — but the caller is told, so it
  /// can say the undo is unavailable rather than offer one that isn't there.
  /// The bytes [capture] needs: enough of the file that `[0, audioOffset)`
  /// lies entirely inside them, or the whole file when that cannot be
  /// established from the header alone.
  ///
  /// A truncated head here would not fail loudly — it would be stored, and
  /// an undo would splice it back over the audio. So every doubt (bad
  /// syncsafe size, tag larger than the file, parse disagreeing with the
  /// header) takes the old path: read everything.
  static Future<Uint8List> _readTagHead(File file) async {
    final raf = await file.open();
    try {
      final length = await raf.length();
      final header = await raf.read(10);
      final isId3 = header.length == 10 &&
          header[0] == 0x49 &&
          header[1] == 0x44 &&
          header[2] == 0x33;

      if (isId3) {
        final syncsafe =
            ((header[6] | header[7] | header[8] | header[9]) & 0x80) == 0;
        if (syncsafe) {
          final size = (header[6] << 21) |
              (header[7] << 14) |
              (header[8] << 7) |
              header[9];
          // ID3v2.4 footer flag: ten more bytes after the tag.
          final footer = (header[3] == 4 && (header[5] & 0x10) != 0) ? 10 : 0;
          final want = 10 + size + footer;
          // A tag larger than the file is the truncated case: the old code
          // backed up the whole file there, and so does the fallback.
          if (want <= length) {
            await raf.setPosition(0);
            final head = await raf.read(want);
            if (head.length == want) {
              final tag = Id3Tag.parse(head);
              if (tag != null && tag.audioOffset <= head.length) return head;
            }
          }
        }
      } else {
        // No ID3 magic. An MP4 announces itself in its first box, and
        // capture answers false for it without using anything else — no
        // reason to read the whole container to say no.
        await raf.setPosition(0);
        final prefix = await raf.read(65536);
        if (AudioContainerReader.detect(prefix) == AudioContainer.mp4) {
          return prefix;
        }
      }
    } finally {
      await raf.close();
    }
    return file.readAsBytes();
  }

  Future<bool> capture(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;

      // The sidecar, if there is one, is backed up with the tag: it is
      // the tap that deletes it, and « Annuler » must put it back. The
      // blob is only ever used when the sidecar is gone at restore time,
      // so the other callers (AI mode, batch, manual embed) pay a few
      // kilobytes and nothing else — their sidecar is never deleted.
      final sidecar = await _backupSidecar(filePath);

      // Only the head: the backup never keeps a byte past audioOffset,
      // and reading 8 MB of audio to copy 4 KB of tag was the batch's
      // first full read per track. Falls back to the whole file
      // whenever the head cannot be bounded with certainty, so the
      // blob stored below is unchanged.
      final bytes = await _readTagHead(file);
      final tag = Id3Tag.parse(bytes);

      // MP4 (audit P8): no ID3 head to splice back, so the backup is the
      // current ©lyr text itself, stored as a small UTF-8 blob
      // (`<key>-<ts>.lyr`). Restoring it rewrites the atom through
      // M4aWriter — the same temp + verify + atomic rename as a lyrics
      // write. An empty blob means "no ©lyr": restoring it removes the
      // atom. Only the lyrics are backed up, not the other metadata
      // atoms — a lyrics write only touches ©lyr, so for the callers
      // here (all lyrics writers) the restore is exact.
      if (tag == null &&
          AudioContainerReader.detect(bytes) == AudioContainer.mp4) {
        return await _captureM4aLyrics(filePath, sidecar: sidecar);
      }

      // A file with no tag backs up as an empty head, which restores correctly:
      // putting nothing in front of the audio is exactly how it started.
      final headLength = (tag?.audioOffset ?? 0).clamp(0, bytes.length);
      final head = Uint8List.sublistView(bytes, 0, headLength);

      final dir = await _dir();
      // One blob per write, not per track: a second write must not overwrite
      // the copy the first one is still relying on.
      final storedAs =
          '${_keyFor(filePath)}-${DateTime.now().microsecondsSinceEpoch}.tag';
      await File(
        '${dir.path}${Platform.pathSeparator}$storedAs',
      ).writeAsBytes(head, flush: true);

      await _recordNewEntry(
        TagBackup(
          filePath: filePath,
          writtenAt: DateTime.now(),
          // The sidecar blob counts toward the size cap with the tag.
          tagBytes: head.length + (sidecar?.bytes ?? 0),
          // Filled in by [markWritten] once the write has landed.
          writtenMtime: 0,
          storedAs: storedAs,
          sidecarStoredAs: sidecar?.storedAs,
          sidecarPath: sidecar?.path,
        ),
      );
      return true;
    } catch (error, stack) {
      // Returning false is correct — the write goes ahead either way, since
      // losing the undo is a smaller harm than refusing to work. But it means
      // the "Annuler" button quietly does not appear, and a feature that
      // silently stops existing is exactly what a log is for.
      DebugLog.instance.error(
        'Sauvegarde',
        'Copie de sécurité impossible : cette écriture ne sera pas annulable',
        error: error,
        stackTrace: stack,
      );
      return false;
    }
  }

  /// Records a fresh backup entry on top of the stack for its track.
  ///
  /// Newest first, past the per-track depth the oldest steps of the
  /// track go, then the global caps. Shared by [capture] (MP3 head
  /// blobs) and [_captureM4aLyrics] (©lyr blobs) so the two cannot
  /// drift apart on trimming.
  Future<void> _recordNewEntry(TagBackup entry) async {
    // A copy: `list()` answers with a const empty list when there is no index
    // yet, and inserting into that throws — which the catch below would turn
    // into "no undo" for the very first write.
    final entries = [...await list()];
    entries.insert(0, entry);

    // Past the per-track depth, the oldest steps of this track go.
    var seen = 0;
    final trimmed = <TagBackup>[];
    for (final e in entries) {
      if (e.filePath == entry.filePath && ++seen > _maxPerFile) {
        await _deleteStored(e);
      } else {
        trimmed.add(e);
      }
    }

    await _writeIndex(await _prune(trimmed));
  }

  /// Saves the current ©lyr text of an M4A file as a `.lyr` blob (P8).
  ///
  /// True when the backup was recorded. Never throws: like [capture], a
  /// failure is reported as false so the caller can refuse a write it
  /// could not undo. An empty blob means the file had no ©lyr.
  Future<bool> _captureM4aLyrics(
    String filePath, {
    _SidecarBackup? sidecar,
  }) async {
    try {
      final text = await M4aWriter.readLrc(filePath);
      final blob = utf8.encode(text ?? '');
      final dir = await _dir();
      final storedAs =
          '${_keyFor(filePath)}-${DateTime.now().microsecondsSinceEpoch}.lyr';
      await File(
        '${dir.path}${Platform.pathSeparator}$storedAs',
      ).writeAsBytes(blob, flush: true);

      await _recordNewEntry(
        TagBackup(
          filePath: filePath,
          writtenAt: DateTime.now(),
          tagBytes: blob.length + (sidecar?.bytes ?? 0),
          // Filled in by [markWritten] once the write has landed.
          writtenMtime: 0,
          storedAs: storedAs,
          sidecarStoredAs: sidecar?.storedAs,
          sidecarPath: sidecar?.path,
        ),
      );
      return true;
    } catch (error, stack) {
      DebugLog.instance.error(
        'Sauvegarde',
        'Copie de sécurité ©lyr impossible : cette écriture ne sera pas annulable',
        error: error,
        stackTrace: stack,
      );
      return false;
    }
  }

  /// Records the track's modification time now that the write is done.
  ///
  /// Separate from [capture] because it can only be known afterwards, and it is
  /// what lets a restore notice that someone else has touched the file since.
  Future<void> markWritten(String filePath) async {
    try {
      final mtime = (await File(
        filePath,
      ).lastModified()).millisecondsSinceEpoch;
      // Only the newest copy of the track: it is the one this write belongs to.
      // Older ones keep the modification time of the write they followed.
      var stamped = false;
      final entries = [
        for (final e in await list())
          if (e.filePath == filePath && !stamped && (stamped = true))
            TagBackup(
              filePath: e.filePath,
              writtenAt: e.writtenAt,
              tagBytes: e.tagBytes,
              writtenMtime: mtime,
              storedAs: e.storedAs,
              sidecarStoredAs: e.sidecarStoredAs,
              sidecarPath: e.sidecarPath,
            )
          else
            e,
      ];
      await _writeIndex(entries);
    } catch (error) {
      // The backup is still restorable; only the "changed since" check is lost —
      // so a later restore will insist on being forced. Worth a line, because
      // that refusal will otherwise look arbitrary when it happens.
      DebugLog.instance.warning(
        'Sauvegarde',
        'Date d\'écriture non enregistrée : une annulation ultérieure demandera '
            'une confirmation',
        error: error,
      );
    }
  }

  /// Puts the recorded tag back.
  ///
  /// Throws [TagRestoreException] with something the user can act on. Set
  /// [force] to go ahead even when the track has changed since Musync wrote it.
  Future<void> restore(String filePath, {bool force = false}) async {
    final entry = await backupFor(filePath);
    if (entry == null) {
      throw const TagRestoreException('Aucune sauvegarde pour ce morceau.');
    }

    final target = File(filePath);
    if (!await target.exists()) {
      throw const TagRestoreException('Le fichier n\'existe plus.');
    }

    if (!force && entry.writtenMtime > 0) {
      final now = (await target.lastModified()).millisecondsSinceEpoch;
      if (now != entry.writtenMtime) {
        throw const TagRestoreException(
          'Le fichier a été modifié depuis. Restaurer écraserait aussi ce '
          'changement.',
        );
      }
    }

    // M4A lyrics backup (P8): the blob holds the previous ©lyr text,
    // empty when there was none. The atom is rewritten through the
    // writer — temp + verify + atomic rename — never spliced.
    if (entry.storedAs.endsWith('.lyr')) {
      await _restoreM4aLyrics(entry, filePath);
      return;
    }

    final dir = await _dir();
    final stored = File(
      '${dir.path}${Platform.pathSeparator}${entry.storedAs}',
    );
    if (!await stored.exists()) {
      throw const TagRestoreException('La sauvegarde est introuvable.');
    }

    final head = await stored.readAsBytes();
    final current = await target.readAsBytes();

    // Where the audio starts *now* — the tag Musync wrote may be a different
    // size from the one being restored, which is the whole reason this splices
    // rather than overwrites in place.
    final audioAt = (Id3Tag.parse(current)?.audioOffset ?? 0).clamp(
      0,
      current.length,
    );

    final temp = File('$filePath.musync.undo');
    try {
      final handle = await temp.open(mode: FileMode.write);
      try {
        await handle.writeFrom(head);
        await handle.writeFrom(current, audioAt);
        await handle.flush();
      } finally {
        await handle.close();
      }
      await temp.rename(filePath);
    } on FileSystemException catch (e) {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // Best effort — the track itself is untouched either way.
        }
      }
      throw TagRestoreException(
        'Restauration impossible : ${e.osError?.message ?? e.message}',
      );
    }

    await _restoreSidecar(entry);
    await _consume(entry, filePath);
  }

  /// The sidecar `.lrc` next to [filePath], if there is one — `.lrc`
  /// then `.LRC`, as the reader does (Android's filesystems are
  /// case-sensitive, and some taggers write uppercase).
  Future<File?> _sidecarFile(String filePath) async {
    final dot = filePath.lastIndexOf('.');
    if (dot < 0) return null;
    final base = filePath.substring(0, dot);
    for (final ext in ['.lrc', '.LRC']) {
      final candidate = File('$base$ext');
      try {
        if (await candidate.exists()) return candidate;
      } catch (_) {}
    }
    return null;
  }

  /// Backs up the sidecar next to [filePath], if there is one. Never
  /// throws: a sidecar that cannot be backed up must not stop the tag
  /// backup — the caller is told by the null, and the write goes ahead
  /// without an undo for the sidecar.
  Future<_SidecarBackup?> _backupSidecar(String filePath) async {
    try {
      final sidecar = await _sidecarFile(filePath);
      if (sidecar == null) return null;
      final bytes = await sidecar.readAsBytes();
      final dir = await _dir();
      final storedAs =
          '${_keyFor(filePath)}-${DateTime.now().microsecondsSinceEpoch}.lrc';
      await File(
        '${dir.path}${Platform.pathSeparator}$storedAs',
      ).writeAsBytes(bytes, flush: true);
      return _SidecarBackup(
        storedAs: storedAs,
        path: sidecar.path,
        bytes: bytes.length,
      );
    } catch (error) {
      DebugLog.instance.warning(
        'Sauvegarde',
        'Sidecar non sauvegardé : $filePath',
        error: error,
      );
      return null;
    }
  }

  /// Deletes the sidecar `.lrc` next to [filePath], if there is one.
  ///
  /// Returns the deleted path, or null when no sidecar existed. Throws
  /// [FileSystemException] when the file exists but cannot be deleted —
  /// the caller reports it, since the lyrics would come back through it.
  Future<String?> deleteSidecar(String filePath) async {
    final sidecar = await _sidecarFile(filePath);
    if (sidecar == null) return null;
    await sidecar.delete();
    return sidecar.path;
  }

  /// Puts a saved ©lyr text back into an M4A file (P8).
  ///
  /// An empty blob removes the atom. A failure to rewrite leaves the
  /// entry in place, so the user can still try again.
  Future<void> _restoreM4aLyrics(TagBackup entry, String filePath) async {
    final dir = await _dir();
    final stored = File(
      '${dir.path}${Platform.pathSeparator}${entry.storedAs}',
    );
    if (!await stored.exists()) {
      throw const TagRestoreException('La sauvegarde est introuvable.');
    }
    final blob = await stored.readAsBytes();
    final text = blob.isEmpty ? null : utf8.decode(blob);
    try {
      await M4aWriter.writeLrc(filePath, text);
    } on M4aWriteException catch (e) {
      throw TagRestoreException('Restauration impossible : ${e.message}');
    }
    await _restoreSidecar(entry);
    await _consume(entry, filePath);
  }

  /// Puts a saved sidecar `.lrc` back — but only when none is there.
  ///
  /// The sidecar was deleted by us, so any file at that path now is
  /// someone else's work (Musicolet re-syncing, another tagger), and
  /// overwriting it would destroy theirs to restore ours. When the
  /// sidecar is simply gone, the bytes go back where they were.
  /// Never throws: the audio restore is the main event, and a sidecar
  /// that cannot come back must not turn it into a failure.
  Future<void> _restoreSidecar(TagBackup entry) async {
    final sidecarPath = entry.sidecarPath;
    final storedAs = entry.sidecarStoredAs;
    if (sidecarPath == null || storedAs == null) return;
    try {
      if (await File(sidecarPath).exists()) {
        DebugLog.instance.info(
          'Sauvegarde',
          'Sidecar présent, non restauré : $sidecarPath',
        );
        return;
      }
      final dir = await _dir();
      final stored = File(
        '${dir.path}${Platform.pathSeparator}$storedAs',
      );
      if (!await stored.exists()) {
        DebugLog.instance.warning(
          'Sauvegarde',
          'Sauvegarde du sidecar introuvable : $storedAs',
        );
        return;
      }
      await AtomicFile.writeBytes(
        File(sidecarPath),
        await stored.readAsBytes(),
      );
    } catch (error) {
      DebugLog.instance.warning(
        'Sauvegarde',
        'Sidecar non restauré : $sidecarPath',
        error: error,
      );
    }
  }

  /// Drops the step that was just restored, leaving the older ones so the next
  /// undo goes one write further back.
  ///
  /// The next older step recorded the modification time of *its* write. The
  /// restore has just rewritten the file, so that time is stale, and left as it
  /// is the next undo would refuse with "modified since". The file is now in
  /// exactly the state that step expects, so it is given the new time.
  Future<void> _consume(TagBackup entry, String filePath) async {
    await _deleteStored(entry);
    final rest = [
      for (final e in await list())
        if (e.storedAs != entry.storedAs) e,
    ];

    final now = (await File(filePath).lastModified()).millisecondsSinceEpoch;
    var stamped = false;
    await _writeIndex([
      for (final e in rest)
        if (e.filePath == filePath && !stamped && (stamped = true))
          TagBackup(
            filePath: e.filePath,
            writtenAt: e.writtenAt,
            tagBytes: e.tagBytes,
            writtenMtime: now,
            storedAs: e.storedAs,
            sidecarStoredAs: e.sidecarStoredAs,
            sidecarPath: e.sidecarPath,
          )
        else
          e,
    ]);
  }

  /// Throws away the newest step of a track only.
  ///
  /// For a write that did not happen: its copy is of a state the file is
  /// already in, and the older steps must survive it.
  Future<void> discardLatest(String filePath) async {
    final entries = [...await list()];
    final index = entries.indexWhere((e) => e.filePath == filePath);
    if (index < 0) return;
    await _deleteStored(entries[index]);
    entries.removeAt(index);
    await _writeIndex(entries);
  }

  /// Drops a backup. Called after a restore — there is nothing left to undo.
  Future<void> forget(String filePath) async {
    final entries = await list();
    final going = entries.where((e) => e.filePath == filePath);
    for (final entry in going) {
      await _deleteStored(entry);
    }
    await _writeIndex(entries.where((e) => e.filePath != filePath).toList());
  }

  Future<void> clear() async {
    for (final entry in await list()) {
      await _deleteStored(entry);
    }
    await _writeIndex(const []);
  }

  Future<void> _deleteStored(TagBackup entry) async {
    try {
      final dir = await _dir();
      final file = File(
        '${dir.path}${Platform.pathSeparator}${entry.storedAs}',
      );
      if (await file.exists()) await file.delete();
      final sidecarStoredAs = entry.sidecarStoredAs;
      if (sidecarStoredAs != null) {
        final sidecarFile = File(
          '${dir.path}${Platform.pathSeparator}$sidecarStoredAs',
        );
        if (await sidecarFile.exists()) await sidecarFile.delete();
      }
    } catch (error) {
      // An orphaned blob costs disk, not correctness; the index is what counts.
      // Once per session: if the directory has become unwritable, every entry
      // will hit this and the repetition adds nothing.
      DebugLog.instance.once(
        'backup-delete',
        LogLevel.info,
        'Sauvegarde',
        'Un fichier de sauvegarde n\'a pas pu être supprimé (espace occupé '
            'inutilement, sans conséquence sur les annulations)',
        error: error,
      );
    }
  }

  /// Trims to the caps, oldest first, deleting the bytes as it goes.
  Future<List<TagBackup>> _prune(List<TagBackup> entries) async {
    final kept = <TagBackup>[];
    var total = 0;

    for (final entry in entries) {
      final withinCount = kept.length < _maxEntries;
      final withinSize = total + entry.tagBytes <= _maxTotalBytes;
      if (withinCount && withinSize) {
        kept.add(entry);
        total += entry.tagBytes;
      } else {
        await _deleteStored(entry);
      }
    }
    return kept;
  }

  /// A file name derived from the path, stable and safe on any filesystem.
  ///
  /// Not the path itself: it contains separators, and on this library plenty of
  /// characters a file name cannot hold.
  static String _keyFor(String filePath) {
    // FNV-1a. Not for security — only to spread paths across distinct names.
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(filePath)) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

/// A backed-up sidecar: where its bytes live, where they came from, and
/// how many there are (for the size cap).
class _SidecarBackup {
  final String storedAs;
  final String path;
  final int bytes;

  const _SidecarBackup({
    required this.storedAs,
    required this.path,
    required this.bytes,
  });
}
