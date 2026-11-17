/// Swapping an edited working copy in over one of the user's audio files.
///
/// The tag editor and the player's « Changer la pochette » both edit a copy
/// in the app's cache, then copy it next to the original and rename it over
/// it, so the original is never left half-written. Both also left files
/// behind: the cache copy (a whole audio file) whenever anything failed, and
/// the `.musync.tmp` sibling — another whole audio file, in the user's music
/// folder — whenever the final rename did. This is that sequence, once, with
/// the cleanup.
library;

import 'dart:io';

abstract final class AudioFileReplace {
  /// Suffix of the sibling temp written next to the target.
  static const String stageSuffix = '.musync.tmp';

  /// Replaces [target]'s contents with [work]'s, atomically.
  ///
  /// [work] is always deleted afterwards, success or failure. On failure the
  /// sibling temp is deleted too and the error is rethrown: [target] is then
  /// exactly as it was.
  static Future<void> commit(File work, File target) async {
    final stage = File('${target.path}$stageSuffix');
    try {
      if (await stage.exists()) await stage.delete();
      await work.copy(stage.path);
      await stage.rename(target.path);
    } catch (_) {
      await deleteQuietly(stage);
      rethrow;
    } finally {
      await deleteQuietly(work);
    }
  }

  /// Deletes [file] if it exists, ignoring every failure: cleanup must never
  /// replace the error that made it necessary.
  static Future<void> deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort.
    }
  }
}
