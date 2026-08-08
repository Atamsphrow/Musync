/// The one path through which lyrics reach a file.
///
/// Both the search screen and the sync editor save through here, so the
/// permission prompt, the error wording and the cache invalidation stay
/// identical between them — three things that are easy to get subtly different
/// when each screen writes its own save button.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';

/// Writes [synced]/[unsynced] into [filePath], asking for write access first
/// if Android hasn't granted it yet.
///
/// Returns true when the file was written. Everything the user needs to know —
/// a refused permission, a tag version Musync won't touch — is surfaced as a
/// snackbar or a dialog here, so callers only have to react to the boolean.
Future<bool> embedLyrics(
  BuildContext context,
  WidgetRef ref, {
  required String filePath,
  SyncedLyrics? synced,
  UnsyncedLyrics? unsynced,
}) async {
  if (!await _ensureWriteAccess(context)) return false;
  if (!context.mounted) return false;

  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(lyricsRepositoryProvider).embedLyrics(
          filePath,
          synced: synced,
          unsynced: unsynced,
        );
  } on Id3WriteException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Échec de l\'enregistrement : $e')),
    );
    return false;
  }

  // The player reads lyrics straight from the file, so its cached copy is now
  // one revision behind.
  ref.invalidate(currentLyricsProvider);
  return true;
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

  ScaffoldMessenger.of(context).showSnackBar(
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
