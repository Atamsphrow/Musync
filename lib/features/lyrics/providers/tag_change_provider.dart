/// What has to happen after a track's tag changes on disk, held at app scope.
///
/// Why this is not simply a few `ref.invalidate` calls at the call site: a
/// `WidgetRef` belongs to the widget that owns it, and both places that need
/// these invalidations outlive their widget.
///
///  * The sync editor pops itself the instant a save lands, so the invalidations
///    that follow the write run against a `ref` whose widget is already gone.
///  * The "Annuler" action sits on a snackbar that lasts eight seconds and is
///    shown by the app-level `ScaffoldMessenger` — it survives navigation by
///    design. Pressing it after leaving the screen used a dead `ref`.
///
/// Both threw `Cannot use ref after the widget was disposed`, which is the same
/// fault the debug panel already caught once on the search screen. The messenger
/// was correctly captured to outlive the screen; the `ref` was not.
///
/// A `Ref` from a plain (non-autoDispose) `Provider` lives as long as the
/// `ProviderContainer` — that is, as long as the app. Reaching for the container
/// through one is what makes these calls safe from a callback with no widget
/// behind it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/tag_backup.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/settings/providers/backup_provider.dart';

final tagChangeProvider = Provider<TagChangeService>(
  (ref) => TagChangeService(ref),
);

class TagChangeService {
  final Ref _ref;

  const TagChangeService(this._ref);

  /// Drops every cached answer that the file just contradicted.
  ///
  /// Called after a write and after a restore, because the two leave exactly the
  /// same things stale. Keeping it in one place is what stops the two paths
  /// drifting apart — the undo used to forget to refresh the backup list.
  void fileChanged(String filePath) {
    // The player reads lyrics straight from the file, so its cached copy is now
    // one revision behind.
    _ref.invalidate(currentLyricsProvider);

    // The track has very likely changed category — out of "sans paroles". The
    // scanner's modification-time check would normally notice on its own, but a
    // write landing inside the same clock tick as the last read would slip past
    // it, so the entry is dropped explicitly.
    _ref.read(lyricsStatusScannerProvider).forget(filePath);
    _ref.invalidate(lyricsStatusProvider);

    // And the history has a new entry, or has lost one.
    _ref.invalidate(tagBackupsProvider);
  }

  /// Puts the previous tag back and refreshes everything that depended on it.
  ///
  /// Returns null on success, or a message for the user. Deliberately does not
  /// throw: the only caller is a snackbar action, and an exception from there
  /// has nowhere to go.
  Future<String?> undo(String filePath) async {
    try {
      await _ref.read(tagBackupStoreProvider).restore(filePath);
    } on TagRestoreException catch (e) {
      DebugLog.instance.warning('Annulation', e.message);
      return e.message;
    }

    // The file changed again, so MediaStore is pointing at the wrong inode
    // until it is told — the same P0 reasoning as the write itself.
    await MediaStore.rescan(filePath);
    fileChanged(filePath);

    DebugLog.instance.info('Annulation', 'Tag restauré : $filePath');
    return null;
  }
}
