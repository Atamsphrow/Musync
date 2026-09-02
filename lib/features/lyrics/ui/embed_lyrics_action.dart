/// The one path through which lyrics reach a file.
///
/// Both the search screen and the sync editor save through here, so the
/// permission prompt, the error wording and the cache invalidation stay
/// identical between them — three things that are easy to get subtly different
/// when each screen writes its own save button.
library;

import 'package:flutter/material.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/lyrics/providers/tag_change_provider.dart';
import 'package:musync/features/settings/providers/backup_provider.dart';

/// What happened to a track.
///
/// Three outcomes and not a boolean, because [keptSynced] is neither a success
/// nor a failure: nothing was written and nothing went wrong. A caller writing
/// to one file wants to say something different in each case, and the batch
/// writer needs to count them separately — which a boolean made impossible
/// without guessing.
enum EmbedOutcome {
  written,

  /// Refused: the incoming lyrics are untimed and the file already holds timed
  /// ones. Writing would have deleted them.
  keptSynced,

  /// Permission refused, an unsupported tag, or a write that failed. The reason
  /// has already been shown to the user.
  failed,
}

/// What to do when untimed lyrics would land on a file that already has timed
/// ones.
///
/// `writeLyrics` replaces the whole of a file's lyrics — every SYLT and USLT
/// goes, and only what is passed comes back. That is right for the sync editor,
/// which is authoritative about its own track and must be able to clear a
/// timing. It is wrong for a match fetched online: a source that only has plain
/// text would silently destroy a calibration the user did by hand, and the file
/// would come back as "texte seul" every time it went through — which is
/// exactly what T16 describes.
enum PlainOverSynced {
  /// Ask first. For a screen where the user is watching one file.
  ask,

  /// Leave the file alone and report [EmbedOutcome.keptSynced]. For the batch,
  /// where a dialog per file is not a review.
  skip,

  /// Write regardless. Only for a caller that owns the whole lyric state.
  replace,
}

/// Writes [synced]/[unsynced] into [filePath], asking for write access first
/// if Android hasn't granted it yet.
///
/// Everything the user needs to know — a refused permission, a tag version
/// Musync won't touch — is surfaced as a snackbar or a dialog here, so callers
/// only have to react to the returned [EmbedOutcome].
Future<EmbedOutcome> embedLyrics(
  BuildContext context,
  WidgetRef ref, {
  required String filePath,
  SyncedLyrics? synced,
  UnsyncedLyrics? unsynced,

  /// See [PlainOverSynced]. Defaults to asking, so a caller that has not
  /// thought about it cannot destroy a timing by omission.
  PlainOverSynced onPlainOverSynced = PlainOverSynced.ask,

  /// Shown with the undo action once the write lands. Callers pass their own
  /// wording — "76 lignes calées", "12 lignes importées" — because only they
  /// know what just happened.
  ///
  /// Empty means say nothing: the batch writer calls this in a loop, and a
  /// hundred stacked snackbars would bury the screen it is running on. Each
  /// write is still backed up, and still undoable from the history.
  String successMessage = 'Paroles enregistrées.',
}) async {
  if (!await _ensureWriteAccess(context)) return EmbedOutcome.failed;
  if (!context.mounted) return EmbedOutcome.failed;

  final messenger = ScaffoldMessenger.of(context);

  // Untimed lyrics must not quietly delete timed ones.
  //
  // `writeLyrics` replaces the file's whole lyric state, which is what the sync
  // editor needs; for a match fetched online it means a source with only plain
  // text wipes a SYLT the user may have spent an evening on. That is T16: a
  // file filed under /Synchroned/ coming back as "texte seul" on every pass,
  // with nothing said about it.
  if ((synced == null || synced.isEmpty) &&
      onPlainOverSynced != PlainOverSynced.replace) {
    // Read from the file rather than from any cached status: the status cache
    // is keyed on mtime and this decision is too important to take on a
    // possibly stale entry.
    final existing = await Id3Reader.readLyrics(filePath);
    final timed = existing.synced;

    if (timed != null && timed.isNotEmpty) {
      DebugLog.instance.info(
        'Id3Writer',
        'Texte seul propose pour $filePath, qui a deja '
            '${timed.length} lignes calees',
      );

      if (onPlainOverSynced == PlainOverSynced.skip) {
        return EmbedOutcome.keptSynced;
      }
      if (!context.mounted) return EmbedOutcome.failed;

      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remplacer des paroles calées ?'),
          content: Text(
            "Ce fichier contient déjà ${timed.length} lignes calées. "
            "Le résultat choisi n'a que du texte : l'enregistrer effacerait "
            "le calage.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Garder le calage'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remplacer'),
            ),
          ],
        ),
      );

      if (replace != true) return EmbedOutcome.keptSynced;
      if (!context.mounted) return EmbedOutcome.failed;
    }
  }

  // Everything that has to survive the screen is resolved here, before the
  // first await.
  //
  // The messenger already was — it belongs to the app, not the route. The
  // invalidations were not, and that was the bug: the sync editor pops itself
  // the moment a save lands, so the `ref.invalidate` calls that follow the write
  // ran against a widget that no longer existed. Same for the undo action, which
  // lives on a snackbar that outlasts the screen on purpose.
  final backups = ref.read(tagBackupStoreProvider);
  final changes = ref.read(tagChangeProvider);
  final repository = ref.read(lyricsRepositoryProvider);

  // Taken before the write, which is the only moment the previous tag still
  // exists. A failure here does not stop the write — losing the ability to undo
  // is a smaller harm than refusing to work — but it does decide whether an
  // undo is offered at all, since offering one that isn't there is worse than
  // offering none.
  final canUndo = await backups.capture(filePath);
  if (!context.mounted) {
    // Nothing will be written now, so the copy just taken is a backup of a
    // state the file is already in. The store keeps a bounded number of them.
    if (canUndo) await backups.forget(filePath);
    return EmbedOutcome.failed;
  }

  try {
    await repository.embedLyrics(filePath, synced: synced, unsynced: unsynced);
  } on Id3WriteException catch (e, stack) {
    // Logged as well as shown: a snackbar is gone in four seconds, and this is
    // the failure the debug panel exists for.
    DebugLog.instance.error(
      'Id3Writer',
      e.message,
      error: e.cause,
      stackTrace: stack,
    );
    // Nothing was written, so the copy taken above is a backup of a state the
    // file is already in. Dropping it matters because the store keeps a bounded
    // number of them: a batch run over an album of unsupported files would
    // otherwise evict every undo the user might actually want.
    if (canUndo) await backups.forget(filePath);
    messenger.showOnly(SnackBar(content: Text(e.message)));
    return EmbedOutcome.failed;
  } catch (e, stack) {
    DebugLog.instance.error(
      'Id3Writer',
      'Échec inattendu de l\'écriture de $filePath',
      error: e,
      stackTrace: stack,
    );
    // Same reasoning as above. An unexpected failure could in principle have
    // written something, but `_rewriteFile` swaps in a temp file only once it is
    // complete, so a half-written track is not a state this can leave behind.
    if (canUndo) await backups.forget(filePath);
    messenger.showOnly(
      SnackBar(content: Text('Échec de l\'enregistrement : $e')),
    );
    return EmbedOutcome.failed;
  }

  DebugLog.instance.info(
    'Id3Writer',
    'Paroles écrites dans $filePath '
        '(${synced != null ? '${synced.length} lignes calées' : 'texte seul'})',
  );

  // Recorded now that the file has settled, so a later restore can tell whether
  // anything else has touched it since. Before the invalidations, so the history
  // list is rebuilt from an entry that is already complete.
  if (canUndo) await backups.markWritten(filePath);

  // Through the app-scoped service, not `ref`: by this point the sync editor may
  // already have popped itself.
  changes.fileChanged(filePath);

  if (successMessage.isNotEmpty) {
    messenger.showOnly(
      SnackBar(
        content: Text(successMessage),
        // Longer than the default four seconds: an undo nobody had time to read
        // is not an undo.
        duration: const Duration(seconds: 6),
        action: canUndo
            ? SnackBarAction(
                label: 'Annuler',
                onPressed: () => _undo(changes, messenger, filePath),
              )
            : null,
      ),
    );
  }
  return EmbedOutcome.written;
}

/// Puts the previous tag back.
///
/// Takes neither the screen's context nor its `ref`. By the time anyone presses
/// this the sync editor has usually closed itself — the messenger belongs to the
/// app and outlives it, and [TagChangeService] holds a container-scoped `Ref`
/// for the same reason. Passing the screen's `WidgetRef` here was a use-after-
/// dispose waiting for someone to leave the screen before the snackbar faded.
Future<void> _undo(
  TagChangeService changes,
  ScaffoldMessengerState messenger,
  String filePath,
) async {
  final failure = await changes.undo(filePath);
  messenger.showOnly(
    SnackBar(content: Text(failure ?? 'Paroles précédentes rétablies.')),
  );
}

/// Explains, then asks. The system screen for "all files access" is a
/// full-screen settings page with no context of its own, so landing on it
/// unannounced reads as the app overreaching.
Future<bool> _ensureWriteAccess(BuildContext context) async {
  if (await PermissionService.hasWriteAccess()) return true;
  if (!context.mounted) return false;

  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.folder_open),
      title: const Text('Autoriser la modification des fichiers'),
      content: const Text(
        'Musync écrit les paroles directement dans vos fichiers audio, sans '
        'créer de fichiers .lrc à côté.\n\n'
        'Depuis Android 11, cela demande l\'autorisation « Accès à tous les '
        'fichiers ». Android va ouvrir ses paramètres : activez Musync dans la '
        'liste, puis revenez.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Continuer'),
        ),
      ],
    ),
  );
  if (accepted != true) return false;

  final outcome = await PermissionService.requestWriteAccess();
  if (outcome == PermissionOutcome.granted) return true;
  if (!context.mounted) return false;

  ScaffoldMessenger.of(context).showOnly(
    SnackBar(
      content: const Text(
        'Sans cette autorisation, Musync ne peut pas écrire les paroles.',
      ),
      action: SnackBarAction(
        label: 'Paramètres',
        onPressed: PermissionService.openSettings,
      ),
    ),
  );
  return false;
}
