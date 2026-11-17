/// The library's other views, behind the bottom navigation bar: Favoris and
/// Historique. « Morceaux » stays the existing screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/library/providers/favorites_provider.dart';
import 'package:musync/features/library/providers/listening_history_provider.dart';
import 'package:musync/features/library/ui/song_collection.dart';

/// The destinations of the library's navigation bar, in order.
enum LibrarySection { songs, favorites, history }

extension LibrarySectionLabel on LibrarySection {
  String get label => switch (this) {
    LibrarySection.songs => 'Morceaux',
    LibrarySection.favorites => 'Favoris',
    LibrarySection.history => 'Historique',
  };

  IconData get icon => switch (this) {
    LibrarySection.songs => Icons.library_music_outlined,
    LibrarySection.favorites => Icons.favorite_border,
    LibrarySection.history => Icons.history,
  };

  IconData get selectedIcon => switch (this) {
    LibrarySection.songs => Icons.library_music,
    LibrarySection.favorites => Icons.favorite,
    LibrarySection.history => Icons.history,
  };
}

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
