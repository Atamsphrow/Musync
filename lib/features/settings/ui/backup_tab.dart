/// Settings › Historique: every write Musync has made, and the way back.
///
/// The snackbar's "Annuler" catches the mistake you notice at once. This is for
/// the one you notice the next day — the wrong lyric matched to a track you
/// weren't listening to at the time.
library;

import 'package:flutter/material.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/core/id3/tag_backup.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/features/lyrics/providers/tag_change_provider.dart';
import 'package:musync/features/settings/providers/backup_provider.dart';

class BackupTab extends ConsumerWidget {
  const BackupTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backupsAsync = ref.watch(tagBackupsProvider);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return backupsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('$error')),
      data: (backups) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    backups.isEmpty
                        ? 'Aucune écriture enregistrée.'
                        : '${backups.length} morceau(x) restaurable(s), '
                              '${_totalSize(backups)}.',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: backups.isEmpty
                      ? null
                      : () => _confirmClear(context, ref),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Tout oublier'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: backups.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Avant chaque écriture, Musync met de côté le tag '
                        'précédent du morceau — les paroles, mais aussi la '
                        'pochette et tout le reste. Il apparaîtra ici, et '
                        'pourra être rétabli.\n\n'
                        'Seul le tag est conservé, jamais l\'audio.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: backups.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        _BackupTile(backup: backups[index]),
                  ),
          ),
        ],
      ),
    );
  }

  static String _totalSize(List<TagBackup> backups) {
    final bytes = backups.fold<int>(0, (sum, b) => sum + b.tagBytes);
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} Ko';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
  }
}

class _BackupTile extends ConsumerWidget {
  final TagBackup backup;

  const _BackupTile({required this.backup});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      title: Text(
        backup.displayName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodyMedium,
      ),
      subtitle: Text(
        '${_when(backup.writtenAt)} · ${(backup.tagBytes / 1024).round()} Ko',
        style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.settings_backup_restore),
        tooltip: 'Rétablir le tag précédent',
        onPressed: () => _restore(context, ref, backup),
      ),
    );
  }

  static String _when(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

Future<void> _restore(
  BuildContext context,
  WidgetRef ref,
  TagBackup backup,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final store = ref.read(tagBackupStoreProvider);
  // Resolved before the dialogs below, and app-scoped rather than tied to this
  // tab: two confirmations and a file rewrite is plenty of time for someone to
  // leave the Settings screen, and `ref` dies with it.
  final changes = ref.read(tagChangeProvider);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rétablir le tag précédent ?'),
      content: Text(
        'Les paroles actuelles de « ${backup.displayName} » seront remplacées '
        'par celles d\'avant l\'écriture du '
        '${_BackupTile._when(backup.writtenAt)}.\n\n'
        'L\'audio n\'est pas touché.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Rétablir'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    await store.restore(backup.filePath);
  } on TagRestoreException catch (e) {
    if (!context.mounted) return;
    // A file touched by something else since is the case worth stopping on, and
    // it is also the one where the user may still want to go ahead.
    final force = await _offerForce(context, e.message);
    if (force != true) {
      messenger.showOnly(SnackBar(content: Text(e.message)));
      return;
    }
    try {
      await store.restore(backup.filePath, force: true);
    } on TagRestoreException catch (e2) {
      messenger.showOnly(SnackBar(content: Text(e2.message)));
      return;
    }
  }

  await MediaStore.rescan(backup.filePath);
  changes.fileChanged(backup.filePath);

  DebugLog.instance.info('Annulation', 'Tag restauré : ${backup.filePath}');
  messenger.showOnly(const SnackBar(content: Text('Tag précédent rétabli.')));
}

/// Asked only when the file has moved on since Musync wrote it.
Future<bool?> _offerForce(BuildContext context, String reason) async {
  if (!context.mounted) return false;
  // Anything other than the "changed since" guard is not something forcing
  // would fix.
  if (!reason.contains('modifié depuis')) return false;

  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Le fichier a changé'),
      content: Text(
        '$reason\n\nRétablir quand même remplacera aussi ce qui a été fait '
        'entre-temps.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Ne rien faire'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Rétablir quand même'),
        ),
      ],
    ),
  );
}

Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Tout oublier ?'),
      content: const Text(
        'Les sauvegardes seront supprimées. Les paroles déjà écrites dans vos '
        'fichiers ne changent pas — vous perdez seulement la possibilité de '
        'revenir en arrière.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Tout oublier'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  await ref.read(tagBackupStoreProvider).clear();
  ref.invalidate(tagBackupsProvider);
}
