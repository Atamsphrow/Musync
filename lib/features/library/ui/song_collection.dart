/// A plain list of tracks with « Tout lire » / « Aléatoire » on top — the
/// body of the Favoris and Historique views.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/router/app_router.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/ui/play_actions.dart';
import 'package:musync/features/library/ui/widgets/song_tile.dart';

/// The list itself: a header (count, Tout lire, Aléatoire) and one
/// [SongTile] per track. A tap plays the list from that track.
class SongCollectionList extends ConsumerWidget {
  const SongCollectionList({super.key, required this.songs, this.empty});

  final List<Song> songs;

  /// Shown instead of the list when [songs] is empty.
  final Widget? empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (songs.isEmpty) {
      return empty ?? const SizedBox.shrink();
    }
    final textTheme = Theme.of(context).textTheme;
    final count = songs.length;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$count morceau${count > 1 ? 'x' : ''}',
                      style: textTheme.bodySmall,
                    ),
                  ),
                  PlaySongsButtons(songs: songs),
                ],
              ),
            ),
          ),
        ),
        SliverFixedExtentList.builder(
          itemExtent: kSongTileHeight,
          itemCount: count,
          itemBuilder: (context, index) => SongTile(
            song: songs[index],
            onTap: () => Navigator.pushNamed(
              context,
              AppRoutes.player,
              arguments: SongRouteArgs(
                song: songs[index],
                queue: songs,
                index: index,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

/// The centred icon-and-text an empty collection shows.
class CollectionEmptyState extends StatelessWidget {
  const CollectionEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

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
              style: textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
