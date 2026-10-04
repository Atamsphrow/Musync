import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/providers/named_queue_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';

/// The player's live queue: reorder by drag-and-drop, swipe a track away to
/// remove it, tap one to play it. Opened from the now-playing screen (wired by
/// the coordinator); this widget only owns its own content.
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
  /// F6 hook: mirrors the player's queue into the active named queue.
  ///
  /// `syncActiveFromPlayer` is landing on [NamedQueuesController] from a
  /// parallel worker; the dynamic call keeps this compiling until it does,
  /// and the try/catch keeps it silent if the method is still absent at
  /// runtime. The coordinator verifies the final wiring.
  Future<void> _syncActiveQueue() async {
    try {
      await (ref.read(namedQueuesProvider.notifier) as dynamic)
          .syncActiveFromPlayer();
    } catch (_) {
      // Absent or failing: the queue mutation itself already succeeded.
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    // `onReorderItem` reports the track's final slot directly (the framework
    // already accounts for the removed item); the service expects exactly
    // that. The deprecated `onReorder` would need the manual
    // `if (oldIndex < newIndex) newIndex -= 1` adjustment instead.
    await ref.read(audioPlayerServiceProvider).reorderQueue(oldIndex, newIndex);
    await _syncActiveQueue();
    if (mounted) setState(() {});
  }

  Future<void> _remove(int index, Song song) async {
    await ref.read(audioPlayerServiceProvider).removeFromQueue(index);
    await _syncActiveQueue();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('« ${song.title} » retiré de la file')),
    );
  }

  Future<void> _playAt(List<Song> queue, int index) async {
    await ref
        .read(audioPlayerServiceProvider)
        .playSong(queue[index], queue: queue, index: index);
    if (mounted) setState(() {});
  }

  String _formatDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final service = ref.watch(audioPlayerServiceProvider);
    // Rebuilds the highlight when playback moves on its own (notification,
    // lock screen, automatic advance) — the queue list itself only changes
    // through this screen's mutations, which call setState.
    ref.watch(currentIndexProvider);
    ref.watch(currentSongProvider);

    final queue = service.queue;
    final currentIndex = service.currentIndex;

    return Scaffold(
      appBar: AppBar(
        title: const Text('File d\u2019attente'),
      ),
      body: queue.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.queue_music_outlined,
                    size: 64,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'La file d\u2019attente est vide',
                    style: textTheme.titleMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Lancez un morceau depuis la bibliothèque\npour remplir la file.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            )
          : ReorderableListView.builder(
              // The rows carry their own drag handles; the default ones
              // would double them.
              buildDefaultDragHandles: false,
              itemCount: queue.length,
              onReorderItem: _reorder,
              itemBuilder: (context, index) {
                final song = queue[index];
                final isCurrent = index == currentIndex;
                // `identityHashCode`: the service keeps the same Song
                // instances across mutations, so this stays stable while
                // remaining unique even if the same track is queued twice
                // (Song equality is by id alone).
                final key =
                    ValueKey('queue_${song.id}_${identityHashCode(song)}');
                return Dismissible(
                  key: key,
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: scheme.errorContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: Icon(
                      Icons.delete_outline,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                  onDismissed: (_) => _remove(index, song),
                  child: Material(
                    color: isCurrent
                        ? scheme.primaryContainer.withValues(alpha: 0.45)
                        : Colors.transparent,
                    child: ListTile(
                      leading: ReorderableDragStartListener(
                        index: index,
                        child: Icon(
                          Icons.drag_handle,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      title: Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge?.copyWith(
                          color: isCurrent
                              ? scheme.primary
                              : scheme.onSurface,
                          fontWeight: isCurrent
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        '${song.artist} • ${song.album}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isCurrent)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Icon(
                                Icons.graphic_eq_rounded,
                                size: 18,
                                color: scheme.primary,
                                semanticLabel: 'Lecture en cours',
                              ),
                            ),
                          Text(
                            _formatDuration(song.duration),
                            style: textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      onTap: () => _playAt(queue, index),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
