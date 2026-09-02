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
import 'package:musync/core/id3/id3_tag.dart';
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

  const TagBackup({
    required this.filePath,
    required this.writtenAt,
    required this.tagBytes,
    required this.writtenMtime,
    required this.storedAs,
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
  static const int _maxEntries = 40;
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
      entries.sort((a, b) => b.writtenAt.compareTo(a.writtenAt));
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
  Future<bool> capture(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;

      final bytes = await file.readAsBytes();
      final tag = Id3Tag.parse(bytes);

      // A file with no tag backs up as an empty head, which restores correctly:
      // putting nothing in front of the audio is exactly how it started.
      final headLength = (tag?.audioOffset ?? 0).clamp(0, bytes.length);
      final head = Uint8List.sublistView(bytes, 0, headLength);

      final dir = await _dir();
      final storedAs = '${_keyFor(filePath)}.tag';
      await File(
        '${dir.path}${Platform.pathSeparator}$storedAs',
      ).writeAsBytes(head, flush: true);

      // Replaces any earlier backup for this track: one per file.
      final entries = (await list())
          .where((e) => e.filePath != filePath)
          .toList();
      entries.insert(
        0,
        TagBackup(
          filePath: filePath,
          writtenAt: DateTime.now(),
          tagBytes: head.length,
          // Filled in by [markWritten] once the write has landed.
          writtenMtime: 0,
          storedAs: storedAs,
        ),
      );

      await _writeIndex(await _prune(entries));
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

  /// Records the track's modification time now that the write is done.
  ///
  /// Separate from [capture] because it can only be known afterwards, and it is
  /// what lets a restore notice that someone else has touched the file since.
  Future<void> markWritten(String filePath) async {
    try {
      final mtime = (await File(
        filePath,
      ).lastModified()).millisecondsSinceEpoch;
      final entries = [
        for (final e in await list())
          if (e.filePath == filePath)
            TagBackup(
              filePath: e.filePath,
              writtenAt: e.writtenAt,
              tagBytes: e.tagBytes,
              writtenMtime: mtime,
              storedAs: e.storedAs,
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

    await forget(filePath);
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
