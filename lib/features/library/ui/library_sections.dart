/// The library's other views, behind the bottom navigation bar: Artistes,
/// Albums, Favoris, Historique. « Morceaux » stays the existing screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/router/app_router.dart';
import 'package:musync/features/library/data/library_groups.dart';
import 'package:musync/features/library/providers/favorites_provider.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/library/providers/listening_history_provider.dart';
import 'package:musync/features/library/ui/song_collection.dart';
import 'package:musync/features/library/ui/widgets/song_artwork.dart';

/// The destinations of the library's navigation bar, in order.
enum LibrarySection { songs, artists, albums, favorites, history }

extension LibrarySectionLabel on LibrarySection {
  String get label => switch (this) {
    LibrarySection.songs => 'Morceaux',
    LibrarySection.artists => 'Artistes',
    LibrarySection.albums => 'Albums',
    LibrarySection.favorites => 'Favoris',
    LibrarySection.history => 'Historique',
  };

  IconData get icon => switch (this) {
    LibrarySection.songs => Icons.library_music_outlined,
    LibrarySection.artists => Icons.person_outline,
    LibrarySection.albums => Icons.album_outlined,
    LibrarySection.favorites => Icons.favorite_border,
    LibrarySection.history => Icons.history,
  };

  IconData get selectedIcon => switch (this) {
    LibrarySection.songs => Icons.library_music,
    LibrarySection.artists => Icons.person,
    LibrarySection.albums => Icons.album,
    LibrarySection.favorites => Icons.favorite,
    LibrarySection.history => Icons.history,
  };
}

/// The artists, one row each; a tap opens their tracks.
final artistGroupsProvider = Provider<AsyncValue<List<ArtistGroup>>>(
  (ref) => ref.watch(songListProvider).whenData(groupByArtist),
);

/// The albums, one row each; a tap opens their tracks in album order.
final albumGroupsProvider = Provider<AsyncValue<List<AlbumGroup>>>(
  (ref) => ref.watch(songListProvider).whenData(groupByAlbum),
);

/// Loading, error and data for the section bodies, in one place.
Widget _asyncBody<T>(
  AsyncValue<T> value,
  Widget Function(T data) data,
) => switch (value) {
  AsyncData(:final value) => data(value),
  AsyncError() => const CollectionEmptyState(
    icon: Icons.error_outline,
    title: 'Bibliothèque illisible',
    message: 'Revenez sur « Morceaux » et tirez vers le bas pour relancer '
        'l’analyse.',
  ),
  _ => const Center(child: CircularProgressIndicator()),
};

String _tracks(int count) => '$count morceau${count > 1 ? 'x' : ''}';

class ArtistsSection extends ConsumerWidget {
  const ArtistsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _asyncBody(ref.watch(artistGroupsProvider), (groups) {
      if (groups.isEmpty) {
        return const CollectionEmptyState(
          icon: Icons.person_off_outlined,
          title: 'Aucun artiste',
          message: 'Les artistes de vos morceaux apparaîtront ici.',
        );
      }
      return ListView.builder(
        itemCount: groups.length,
        padding: const EdgeInsets.only(bottom: 24),
        itemBuilder: (context, index) {
          final group = groups[index];
          return ListTile(
            minVerticalPadding: 8,
            leading: ClipOval(
              child: _Cover(songId: group.songs.first.id, size: 48),
            ),
            title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(_tracks(group.songs.length)),
            onTap: () => Navigator.pushNamed(
              context,
              AppRoutes.collection,
              arguments: CollectionRouteArgs(
                title: group.name,
                subtitle: _tracks(group.songs.length),
                songs: group.songs,
              ),
            ),
          );
        },
      );
    });
  }
}

class AlbumsSection extends ConsumerWidget {
  const AlbumsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _asyncBody(ref.watch(albumGroupsProvider), (groups) {
      if (groups.isEmpty) {
        return const CollectionEmptyState(
          icon: Icons.album_outlined,
          title: 'Aucun album',
          message: 'Les albums de vos morceaux apparaîtront ici.',
        );
      }
      return ListView.builder(
        itemCount: groups.length,
        padding: const EdgeInsets.only(bottom: 24),
        itemBuilder: (context, index) {
          final group = groups[index];
          final subtitle = '${group.artist} · ${_tracks(group.songs.length)}';
          return ListTile(
            minVerticalPadding: 8,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _Cover(songId: group.songs.first.id, size: 56),
            ),
            title: Text(
              group.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.pushNamed(
              context,
              AppRoutes.collection,
              arguments: CollectionRouteArgs(
                title: group.title,
                subtitle: subtitle,
                songs: group.songs,
              ),
            ),
          );
        },
      );
    });
  }
}

class FavoritesSection extends ConsumerWidget {
  const FavoritesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _asyncBody(
      ref.watch(favoriteSongsProvider),
      (songs) => SongCollectionList(
        songs: songs,
        empty: const CollectionEmptyState(
          icon: Icons.favorite_border,
          title: 'Aucun favori',
          message: 'Touchez « Favori » dans Lecture en cours pour retrouver '
              'un morceau ici.',
        ),
      ),
    );
  }
}

/// Which list the history shows.
enum _HistoryOrder { recent, mostPlayed }

class HistorySection extends ConsumerStatefulWidget {
  const HistorySection({super.key});

  @override
  ConsumerState<HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends ConsumerState<HistorySection> {
  _HistoryOrder _order = _HistoryOrder.recent;

  @override
  Widget build(BuildContext context) {
    final songs = ref.watch(
      _order == _HistoryOrder.recent
          ? recentSongsProvider
          : mostPlayedSongsProvider,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SegmentedButton<_HistoryOrder>(
            segments: const [
              ButtonSegment(
                value: _HistoryOrder.recent,
                icon: Icon(Icons.schedule),
                label: Text('Récents'),
              ),
              ButtonSegment(
                value: _HistoryOrder.mostPlayed,
                icon: Icon(Icons.trending_up),
                label: Text('Les plus écoutés'),
              ),
            ],
            selected: {_order},
            onSelectionChanged: (s) => setState(() => _order = s.first),
            showSelectedIcon: false,
          ),
        ),
        Expanded(
          child: _asyncBody(
            songs,
            (list) => SongCollectionList(
              songs: list,
              empty: const CollectionEmptyState(
                icon: Icons.history,
                title: 'Rien pour l’instant',
                message: 'Un morceau écouté plus de 30 secondes apparaît '
                    'ici.',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Asks before wiping the history; the app bar's action in Historique.
Future<void> confirmClearHistory(BuildContext context, WidgetRef ref) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.delete_sweep_outlined),
      title: const Text('Effacer l’historique ?'),
      content: const Text(
        'Les écoutes récentes et les compteurs sont supprimés. Vos morceaux '
        'et vos favoris ne changent pas.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Effacer'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await ref.read(listeningHistoryProvider.notifier).clear();
  }
}

/// A square cover from the list-thumbnail cache, with the usual placeholder.
class _Cover extends StatelessWidget {
  const _Cover({required this.songId, required this.size});

  final int songId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SongArtwork(
      songId: songId,
      size: size,
      placeholder: Container(
        width: size,
        height: size,
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.music_note, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
