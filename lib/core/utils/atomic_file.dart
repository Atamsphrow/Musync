/// Replacing a file's contents without ever leaving a broken one behind.
///
/// Six places in this app wrote `<file>.tmp` and renamed it over the target, and
/// all six shared a fault the user's own debug log caught:
///
/// ```
/// [Catalogue] Cache des statuts non enregistré
///   PathNotFoundException: Cannot rename file to '…/lyrics_status_cache.json',
///   path = '…/lyrics_status_cache.json.tmp' (errno = 2)
/// ```
///
/// Two writes overlapped. Both wrote the same temp file, the first rename
/// consumed it, and the second found its own source gone. Nothing was corrupted
/// — the rename is still atomic — but one write was silently lost, and for the
/// status cache that means a slow start on every launch afterwards.
///
/// The fix is to serialise writes per path rather than to invent a unique temp
/// name for each: one name means at most one orphan left behind by a process
/// killed mid-write, which is the same bound the original design accepted.
library;

import 'dart:io';

import 'package:synchronized/synchronized.dart';

abstract final class AtomicFile {
  /// One lock per target path. Writes to different files never wait on each
  /// other; writes to the same file queue.
  static final Map<String, Lock> _locks = <String, Lock>{};

  static Lock _lockFor(String path) => _locks.putIfAbsent(path, Lock.new);

  /// Writes [contents] over [file], atomically.
  static Future<void> writeString(File file, String contents) =>
      _replace(file, (temp) => temp.writeAsString(contents, flush: true));

  /// Writes [bytes] over [file], atomically.
  static Future<void> writeBytes(File file, List<int> bytes) =>
      _replace(file, (temp) => temp.writeAsBytes(bytes, flush: true));

  /// Fills a temp file with [fill], then swaps it in.
  ///
  /// A failure anywhere leaves the previous contents untouched and takes the
  /// temp file with it, so a retry starts from a clean state.
  static Future<void> _replace(
    File file,
    Future<void> Function(File temp) fill,
  ) {
    return _lockFor(file.path).synchronized(() async {
      final temp = File('${file.path}.tmp');
      try {
        // The parent may be gone — Android clears a cache directory whenever it
        // likes, and app data can be cleared under a running process.
        final parent = file.parent;
        if (!await parent.exists()) await parent.create(recursive: true);

        await fill(temp);
        await temp.rename(file.path);
      } catch (_) {
        if (await temp.exists()) {
          try {
            await temp.delete();
          } on FileSystemException {
            // Best effort — the target is untouched either way.
          }
        }
        rethrow;
      }
    });
  }
}
