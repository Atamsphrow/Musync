import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/player/data/named_queue.dart';
import 'package:musync/features/player/providers/named_queue_provider.dart';

/// Ouvre le bottom sheet de gestion des files d'attente (F6).
Future<void> showQueuesSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const QueuesSheet(),
  );
}

/// Liste les files d'attente nommées et permet de les gérer :
/// activer au tap, créer, renommer, supprimer, remplacer par la file
/// en cours de lecture.
class QueuesSheet extends ConsumerWidget {
  const QueuesSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(namedQueuesProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
            child: Row(
              children: [
                Text(
                  'Files d\u2019attente',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: state.loaded
                      ? () => _openCreateDialog(context, ref)
                      : null,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Nouvelle file'),
                ),
              ],
            ),
          ),
          if (!state.loaded)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: CircularProgressIndicator(),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              itemCount: state.queues.length,
              itemBuilder: (context, index) {
                final queue = state.queues[index];
                return _QueueTile(
                  queue: queue,
                  isActive: queue.id == state.activeId,
                );
              },
            ),
          // Laisse un peu d'air sous la liste quand elle est courte.
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// Une file de la liste : tap = activer, menu = renommer / remplacer /
/// supprimer.
class _QueueTile extends ConsumerWidget {
  final NamedQueue queue;
  final bool isActive;

  const _QueueTile({required this.queue, required this.isActive});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      selected: isActive,
      selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.35),
      title: Text(
        queue.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isActive
            ? TextStyle(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              )
            : null,
      ),
      subtitle: Text(_trackCount(queue.length)),
      onTap: () => _activate(context, ref, queue),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isActive) const _ActiveBadge(),
          PopupMenuButton<_QueueAction>(
            tooltip: 'Actions',
            onSelected: (action) => _onAction(context, ref, queue, action),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _QueueAction.rename,
                child: ListTile(
                  leading: Icon(Icons.drive_file_rename_outline),
                  title: Text('Renommer'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: _QueueAction.replace,
                child: ListTile(
                  leading: Icon(Icons.swap_horiz),
                  title: Text('Remplacer par la file actuelle'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              PopupMenuItem(
                value: _QueueAction.delete,
                enabled: queue.id != kDefaultQueueId,
                child: ListTile(
                  leading: Icon(
                    Icons.delete_outline,
                    color: queue.id == kDefaultQueueId
                        ? Theme.of(context).disabledColor
                        : null,
                  ),
                  title: const Text('Supprimer'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _onAction(
    BuildContext context,
    WidgetRef ref,
    NamedQueue queue,
    _QueueAction action,
  ) async {
    switch (action) {
      case _QueueAction.rename:
        await _openRenameDialog(context, ref, queue);
      case _QueueAction.replace:
        await _confirmReplace(context, ref, queue);
      case _QueueAction.delete:
        await _confirmDelete(context, ref, queue);
    }
  }

  Future<void> _activate(
    BuildContext context,
    WidgetRef ref,
    NamedQueue queue,
  ) async {
    await ref.read(namedQueuesProvider.notifier).activate(queue.id);
    if (context.mounted) Navigator.pop(context);
  }
}

enum _QueueAction { rename, replace, delete }

/// Pastille affichée sur la file active.
class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Active',
        style: TextStyle(
          color: colorScheme.onPrimaryContainer,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _trackCount(int n) => n <= 1 ? '$n morceau' : '$n morceaux';

/// Dialogue de création : le nom saisi, puis `create` capture la file
/// actuelle du lecteur dans la nouvelle file.
Future<void> _openCreateDialog(BuildContext context, WidgetRef ref) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) => const _QueueNameDialog(
      title: 'Nouvelle file',
      confirmLabel: 'Créer',
    ),
  );
  if (name == null || !context.mounted) return;
  final notifier = ref.read(namedQueuesProvider.notifier);
  final id = await notifier.create(name);
  if (!context.mounted) return;
  final created = ref
      .read(namedQueuesProvider)
      .queues
      .where((q) => q.id == id)
      .firstOrNull;
  ScaffoldMessenger.of(context).showOnly(
    SnackBar(
      content: Text('« ${created?.name ?? name} » créée avec la file actuelle'),
    ),
  );
}

/// Dialogue de renommage, pré-rempli avec le nom actuel.
Future<void> _openRenameDialog(
  BuildContext context,
  WidgetRef ref,
  NamedQueue queue,
) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) => _QueueNameDialog(
      title: 'Renommer « ${queue.name} »',
      confirmLabel: 'Renommer',
      initialName: queue.name,
    ),
  );
  if (name == null || !context.mounted) return;
  await ref.read(namedQueuesProvider.notifier).rename(queue.id, name);
}

/// Confirmation de suppression. La file par défaut n'arrive jamais ici :
/// son entrée de menu est désactivée.
Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  NamedQueue queue,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Supprimer « ${queue.name} » ?'),
      content: const Text(
        'La file sera définitivement supprimée. '
        'Les morceaux restent dans votre bibliothèque.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final deleted =
      await ref.read(namedQueuesProvider.notifier).delete(queue.id);
  if (!context.mounted || !deleted) return;
  ScaffoldMessenger.of(context).showOnly(
    SnackBar(content: Text('« ${queue.name} » supprimée')),
  );
}

/// Confirmation avant d'écraser le contenu d'une file par la file en cours.
Future<void> _confirmReplace(
  BuildContext context,
  WidgetRef ref,
  NamedQueue queue,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remplacer « ${queue.name} » ?'),
      content: const Text(
        'Son contenu sera remplacé par la file en cours de lecture.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Remplacer'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final replaced = await ref
      .read(namedQueuesProvider.notifier)
      .replaceWithCurrent(queue.id);
  if (!context.mounted || !replaced) return;
  ScaffoldMessenger.of(context).showOnly(
    SnackBar(content: Text('« ${queue.name} » remplacée par la file actuelle')),
  );
}

/// Saisie du nom d'une file. Possède son contrôleur : il est disposé quand
/// le dialogue se ferme, pas après l'`await showDialog`.
class _QueueNameDialog extends StatefulWidget {
  final String title;
  final String confirmLabel;
  final String? initialName;

  const _QueueNameDialog({
    required this.title,
    required this.confirmLabel,
    this.initialName,
  });

  @override
  State<_QueueNameDialog> createState() => _QueueNameDialogState();
}

class _QueueNameDialogState extends State<_QueueNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Nom de la file',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());
}
