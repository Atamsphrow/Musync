/// Settings › Bibliothèque: directories the library scan must skip.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/library/data/excluded_dirs_store.dart';
import 'package:musync/features/settings/providers/excluded_dirs_provider.dart';

/// The folders excluded from the library scan, with their sub-folders.
///
/// Adding or removing a folder invalidates `songListProvider` — the rescan is
/// automatic, the snackbar only says it is happening.
class LibraryTab extends ConsumerWidget {
  const LibraryTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final excludedAsync = ref.watch(excludedDirsProvider);

    return Scaffold(
      body: excludedAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (dirs) => dirs.isEmpty
            ? const _EmptyState()
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                itemCount: dirs.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) =>
                    _ExcludedDirTile(path: dirs[index]),
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addDirectory(context, ref),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Ajouter un dossier'),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Aucun dossier exclu : toute la bibliothèque est analysée.',
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _ExcludedDirTile extends ConsumerWidget {
  final String path;

  const _ExcludedDirTile({required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.folder_off_outlined),
      title: Text(path, maxLines: 1, overflow: TextOverflow.fade),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Retirer l\'exclusion',
        onPressed: () => _confirmRemove(context, ref, path),
      ),
    );
  }
}

/// Picks a folder, persisting it through [ExcludedDirsNotifier].
///
/// `getDirectoryPath` throws on a platform failure rather than returning
/// null, which a folder dialog can do on some devices — hence the manual
/// entry fallback rather than a bare try/catch that swallows it.
Future<void> _addDirectory(BuildContext context, WidgetRef ref) async {
  String? chosen;
  try {
    chosen = await FilePicker.getDirectoryPath(
      dialogTitle: 'Dossier à exclure',
    );
  } catch (_) {
    // Platform picker unavailable: let the user type or paste the path.
    chosen = null;
    if (context.mounted) {
      chosen = await _askForPath(context);
    }
  }
  if (chosen == null) return;
  if (!context.mounted) return;

  final dir = ExcludedDirsStore.normalise(chosen);
  if (dir.isEmpty) return;

  final messenger = ScaffoldMessenger.of(context);
  final current =
      ref.read(excludedDirsProvider).valueOrNull ?? const <String>[];
  if (ExcludedDirsStore.isExcluded(dir, current)) {
    messenger.showOnly(const SnackBar(content: Text('Dossier déjà exclu.')));
    return;
  }

  await ref.read(excludedDirsProvider.notifier).add(dir);
  if (!context.mounted) return;
  messenger.showOnly(
    const SnackBar(
      content: Text('Dossiers exclus mis à jour — rescan en cours.'),
    ),
  );
}

Future<void> _confirmRemove(
  BuildContext context,
  WidgetRef ref,
  String path,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Retirer l\'exclusion ?'),
      content: Text('« $path » sera de nouveau analysé lors du prochain scan.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Retirer'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  await ref.read(excludedDirsProvider.notifier).remove(path);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showOnly(
    const SnackBar(
      content: Text('Dossiers exclus mis à jour — rescan en cours.'),
    ),
  );
}

/// Manual entry fallback when the folder picker is unusable on this device.
Future<String?> _askForPath(BuildContext context) async {
  final controller = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ajouter un dossier'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          keyboardType: TextInputType.text,
          onSubmitted: (_) => Navigator.pop(
            context,
            controller.text.trim().isEmpty ? null : controller.text.trim(),
          ),
          decoration: const InputDecoration(
            labelText: 'Chemin du dossier',
            hintText: '/storage/emulated/0/MonDossier',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              controller.text.trim().isEmpty ? null : controller.text.trim(),
            ),
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}
