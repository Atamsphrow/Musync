/// Settings › Bibliothèque : ce que le scan de la bibliothèque doit sauter.
///
/// Dossiers entiers et fichiers individuels, dans deux sections. L'ajout ou
/// le retrait d'une entrée invalide `songListProvider` — le rescan est
/// automatique, le snackbar dit seulement qu'il est en cours.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/library/data/excluded_dirs_store.dart';
import 'package:musync/features/settings/providers/excluded_dirs_provider.dart';
import 'package:musync/features/settings/providers/excluded_files_provider.dart';

class LibraryTab extends ConsumerWidget {
  const LibraryTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirsAsync = ref.watch(excludedDirsProvider);
    final filesAsync = ref.watch(excludedFilesProvider);

    return Scaffold(
      body: switch ((dirsAsync, filesAsync)) {
        (AsyncData(:final value), AsyncData(value: final files)) => ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
              children: [
                const _SectionHeader(title: 'Dossiers exclus'),
                if (value.isEmpty)
                  const _EmptyLine(text: 'Aucun dossier exclu.')
                else
                  for (final dir in value) _ExcludedDirTile(path: dir),
                const SizedBox(height: 4),
                const _SectionHeader(title: 'Fichiers exclus'),
                if (files.isEmpty)
                  const _EmptyLine(text: 'Aucun fichier exclu.')
                else
                  for (final file in files) _ExcludedFileTile(path: file),
              ],
            ),
        _ => const Center(child: CircularProgressIndicator()),
      },
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addDirectory(context, ref),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Ajouter un dossier'),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Text(
        title,
        style: textTheme.titleSmall?.copyWith(color: scheme.primary),
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  final String text;

  const _EmptyLine({required this.text});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Text(
        text,
        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
        onPressed: () => _confirmRemove(context, ref, path, isFile: false),
      ),
    );
  }
}

class _ExcludedFileTile extends ConsumerWidget {
  final String path;

  const _ExcludedFileTile({required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.audio_file_outlined),
      title: Text(path, maxLines: 1, overflow: TextOverflow.fade),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Retirer l\'exclusion',
        onPressed: () => _confirmRemove(context, ref, path, isFile: true),
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
  String path, {
  required bool isFile,
}) async {
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

  if (isFile) {
    await ref.read(excludedFilesProvider.notifier).remove(path);
  } else {
    await ref.read(excludedDirsProvider.notifier).remove(path);
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showOnly(
    SnackBar(
      content: Text(
        isFile
            ? 'Fichiers exclus mis à jour — rescan en cours.'
            : 'Dossiers exclus mis à jour — rescan en cours.',
      ),
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
