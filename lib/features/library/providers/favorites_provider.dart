/// Favourite tracks: the ♥ in « Lecture en cours » and the Favoris view.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/favorites_store.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';

final favoritesStoreProvider = Provider<FavoritesStore>(
  (ref) => const FavoritesStore(),
);

/// The favourite paths, oldest first. Synchronous, like the appearance
/// settings: the ♥ reads it on every build, and a heart that flickers
/// through a loading state on each track change would be worse than none.
final favoritesProvider = NotifierProvider<FavoritesNotifier, List<String>>(
  FavoritesNotifier.new,
);

class FavoritesNotifier extends Notifier<List<String>> {
  /// Set by the first [toggle]: a load landing after it must not overwrite
  /// what the user just did.
  bool _touched = false;

  @override
  List<String> build() {
    // The notifier outlives a rebuild (an import invalidates it): start
    // over, so the reload replaces the list instead of merging the old one.
    _touched = false;
    unawaited(_hydrate());
    return const [];
  }

  Future<void> _hydrate() async {
    final loaded = await ref.read(favoritesStoreProvider).load();
    if (_touched) {
      // Merge rather than drop: keep both the stored list and the taps made
      // before it arrived.
      final merged = [...loaded];
      for (final path in state) {
        if (!merged.contains(path)) merged.add(path);
      }
      state = List.unmodifiable(merged);
      return;
    }
    state = loaded;
  }

  bool isFavorite(String path) => state.contains(path);

  /// Adds [song] to the favourites, or removes it. Returns whether it is a
  /// favourite now.
  Future<bool> toggle(Song song) async {
    _touched = true;
    final path = song.filePath;
    final now = !state.contains(path);
    state = List.unmodifiable(
      now ? [...state, path] : [for (final p in state) if (p != path) p],
    );
    try {
      await ref.read(favoritesStoreProvider).save(state);
    } catch (error, stack) {
      // Already true in the app; losing it only costs the next launch.
      DebugLog.instance.error(
        'Favoris',
        'Enregistrement des favoris impossible',
        error: error,
        stackTrace: stack,
      );
    }
    return now;
  }
}

/// The favourites that are in the library right now, most recent first.
/// A favourite whose file is gone (deleted, moved, excluded) is simply not
/// listed — it comes back if the file does.
final favoriteSongsProvider = Provider<AsyncValue<List<Song>>>((ref) {
  final favorites = ref.watch(favoritesProvider);
  return ref.watch(songListProvider).whenData((songs) {
    final byPath = {for (final s in songs) s.filePath: s};
    return [
      for (final path in favorites.reversed) ?byPath[path],
    ];
  });
});
