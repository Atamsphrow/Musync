import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/core/router/app_router.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';

/// Library browsed as a folder tree, built from the songs' [Song.filePath].
///
/// The tree starts at the first folder where the scanned paths branch out,
/// so `/storage/emulated/0/Music/...` shows `Music` as its root rather than
/// a useless `storage › emulated › 0` chain. Each folder shows the number of
/// tracks it contains (subfolders included); tapping a track opens it in the
/// player with the folder's tracks as the queue — the same route the song
/// tiles in the library use.
class FoldersScreen extends ConsumerWidget {
  const FoldersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songsAsync = ref.watch(songListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Dossiers')),
      body: switch (songsAsync) {
        AsyncData(:final value) when value.isEmpty => const _CenteredMessage(
          icon: Icons.folder_outlined,
          title: 'Aucun morceau trouvé',
          message:
              'Musync n\'a trouvé aucun fichier audio sur cet appareil.',
        ),
        AsyncData(:final value) => ListView(
          children: [
            for (final node in _FolderTree.build(value).roots)
              _FolderTile(node: node),
          ],
        ),
        AsyncError(:final error) => _CenteredMessage(
          icon: Icons.error_outline,
          title: 'Analyse impossible',
          message: '$error',
          action: FilledButton.icon(
            onPressed: () => ref.read(songListProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Réessayer'),
          ),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// One folder of the tree, expandable, showing its subfolders then its tracks.
class _FolderTile extends ConsumerWidget {
  final _FolderNode node;

  const _FolderTile({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ExpansionTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(node.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${node.songCount} morceau${node.songCount > 1 ? 'x' : ''}',
        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      children: [
        for (final child in node.children) _FolderTile(node: child),
        for (final entry in node.songs.asMap().entries)
          _TrackTile(
            song: entry.value,
            // The queue is this folder's tracks in the order shown, so
            // playback continues through the folder instead of stopping
            // after one track.
            queue: node.allSongs,
            index: node.allSongs.indexOf(entry.value),
          ),
      ],
    );
  }
}

class _TrackTile extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int index;

  const _TrackTile({
    required this.song,
    required this.queue,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 56, right: 16),
      leading: Icon(Icons.music_note, color: scheme.onSurfaceVariant),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${song.artist} • ${song.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => Navigator.pushNamed(
        context,
        AppRoutes.player,
        arguments: SongRouteArgs(song: song, queue: queue, index: index),
      ),
    );
  }
}

/// A directory of the scanned library: its own tracks plus its subfolders.
class _FolderNode {
  final String name;
  final List<_FolderNode> children = [];
  final List<Song> songs = [];

  _FolderNode(this.name);

  int get songCount =>
      songs.length + children.fold(0, (sum, child) => sum + child.songCount);

  /// Tracks of this subtree in display order: subfolders first, then the
  /// folder's own tracks.
  List<Song> get allSongs => [
    for (final child in children) ...child.allSongs,
    ...songs,
  ];
}

/// Builds the folder tree from absolute file paths.
///
/// Paths are Android absolute paths, so `/` is the separator. Roots are the
/// folders of the shallowest branching level: a single chain of folders with
/// no branching is collapsed, so the tree starts where it becomes useful.
class _FolderTree {
  final List<_FolderNode> roots;

  _FolderTree(this.roots);

  static _FolderTree build(List<Song> songs) {
    final byPath = <String, _FolderNode>{};

    _FolderNode nodeFor(String dirPath) {
      return byPath.putIfAbsent(dirPath, () {
        // A song without any directory in its path (should not happen on
        // Android, where paths are absolute) still gets a readable name.
        final node = _FolderNode(
          dirPath.isEmpty ? 'Racine' : _basename(dirPath),
        );
        final parent = _dirname(dirPath);
        // A top-level directory has no parent to attach to.
        if (parent != dirPath && parent.isNotEmpty) {
          nodeFor(parent).children.add(node);
        }
        return node;
      });
    }

    for (final song in songs) {
      nodeFor(_dirname(song.filePath)).songs.add(song);
    }

    int compareNames(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());

    void sortNode(_FolderNode node) {
      node.children.sort((a, b) => compareNames(a.name, b.name));
      node.songs.sort((a, b) => compareNames(a.title, b.title));
      for (final child in node.children) {
        sortNode(child);
      }
    }
    // Roots are the directories nothing else nests under: exactly the nodes
    // that were never added as a child.
    final childPaths = {
      for (final node in byPath.values)
        for (final child in node.children) child,
    };
    var roots = [
      for (final node in byPath.values)
        if (!childPaths.contains(node)) node,
    ];
    roots.sort((a, b) => compareNames(a.name, b.name));
    for (final root in roots) {
      sortNode(root);
    }

    // Collapse unbranched chains: one root, one child, no tracks of its own
    // means that level adds nothing to the navigation.
    while (roots.length == 1 &&
        roots.single.children.length == 1 &&
        roots.single.songs.isEmpty) {
      roots = roots.single.children;
    }

    return _FolderTree(roots);
  }

  static String _dirname(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '' : path.substring(0, i);
  }

  static String _basename(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }
}

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: scheme.onSurfaceVariant),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(color: scheme.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}
