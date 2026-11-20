/// Favourite tracks: the ♥ in « Lecture en cours » and the Favoris view.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

  /// What each favourite was when the library last listed it (see
  /// [FavoriteKey]), to find it again after a rename made elsewhere.
  Map<String, FavoriteKey> _keys = const {};

  /// The load in flight: [reconcile] and [movePath] wait for it, so they
  /// never work on the empty list of the first frames.
  Future<void> _hydration = Future.value();

  @override
  List<String> build() {
    // The notifier outlives a rebuild (an import invalidates it): start
    // over, so the reload replaces the list instead of merging the old one.
    _touched = false;
    _keys = const {};
    _hydration = _hydrate();
    return const [];
  }

  Future<void> _hydrate() async {
    final store = ref.read(favoritesStoreProvider);
    final loaded = await store.load();
    final keys = await store.loadKeys();
    // Keys noted by taps made before the load win: they are newer.
    _keys = {...keys, ..._keys};
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
    _keys = {
      for (final entry in _keys.entries)
        if (entry.key != path) entry.key: entry.value,
      if (now) path: FavoriteKey.of(song),
    };
    await _save(keys: true);
    return now;
  }

  /// The app renamed or moved a file: its favourite follows it.
  Future<void> movePath(String oldPath, String newPath) async {
    await _hydration;
    if (oldPath == newPath || !state.contains(oldPath)) return;
    final already = state.contains(newPath);
    state = List.unmodifiable([
      for (final path in state)
        if (path != oldPath)
          path
        else if (!already)
          newPath,
    ]);
    final key = _keys[oldPath];
    _keys = {
      for (final entry in _keys.entries)
        if (entry.key != oldPath) entry.key: entry.value,
      if (key != null && !already) newPath: key,
    };
    await _save(keys: true);
  }

  /// A scan finished: favourites whose file was renamed or moved outside
  /// the app follow it (see [reconcileFavorites]), and what each favourite
  /// is now is noted for the next time. Writes only what changed.
  ///
  /// [fileExists] is for tests; the app checks the disk.
  Future<void> reconcile(
    List<Song> songs, {
    bool Function(String path)? fileExists,
  }) async {
    await _hydration;
    // A scan that found nothing (permission refused, storage not mounted)
    // says nothing about where the files went.
    if (songs.isEmpty) return;
    final result = reconcileFavorites(
      favorites: state,
      keys: _keys,
      songs: songs,
      fileExists: fileExists ?? (path) => File(path).existsSync(),
    );
    final moved = !listEquals(result.favorites, state);
    final keysChanged = !mapEquals(result.keys, _keys);
    if (!moved && !keysChanged) return;
    if (moved) {
      var count = 0;
      for (var i = 0; i < state.length; i++) {
        if (state[i] != result.favorites[i]) count++;
      }
      DebugLog.instance.info(
        'Favoris',
        '$count favori(s) retrouvé(s) après un renommage ou un déplacement',
      );
      state = List.unmodifiable(result.favorites);
    }
    _keys = result.keys;
    await _save(keys: keysChanged, list: moved);
  }

  Future<void> _save({bool list = true, bool keys = false}) async {
    final store = ref.read(favoritesStoreProvider);
    try {
      if (list) await store.save(state);
      if (keys) await store.saveKeys(_keys);
    } catch (error, stack) {
      // Already true in the app; losing it only costs the next launch.
      DebugLog.instance.error(
        'Favoris',
        'Enregistrement des favoris impossible',
        error: error,
        stackTrace: stack,
      );
    }
  }
}

/// Keeps the favourites on their tracks: every finished scan goes through
/// [FavoritesNotifier.reconcile]. Started once by the app root.
final favoritesReconcilerProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<List<Song>>>(songListProvider, (_, next) {
    // Not the previous list a refresh still carries: the new one only.
    if (next case AsyncData(:final value)) {
      unawaited(ref.read(favoritesProvider.notifier).reconcile(value));
    }
  }, fireImmediately: true);
});

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
