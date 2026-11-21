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
  /// False until the stored list is in [state]. Until then a tap changes
  /// the screen at once but is only noted in [_beforeLoad]: saved then, the
  /// near-empty list of the first frames would overwrite every favourite
  /// on disk.
  bool _loaded = false;

  /// Taps made before the load landed, in order: the path and whether it
  /// was added. Replayed on top of the stored list, then saved with it.
  final List<(String, bool)> _beforeLoad = [];

  /// Bumped by each [build], so a load started by an earlier one (before an
  /// import invalidated the provider) cannot land over the new one.
  int _generation = 0;

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
    _loaded = false;
    _beforeLoad.clear();
    _keys = const {};
    _hydration = _hydrate(++_generation);
    return const [];
  }

  Future<void> _hydrate(int generation) async {
    final store = ref.read(favoritesStoreProvider);
    final loaded = await store.load();
    final storedKeys = await store.loadKeys();
    if (generation != _generation) return; // Rebuilt meanwhile.
    final list = [...loaded];
    final keys = {...storedKeys};
    // The taps made before the load, in the order they were made: each is
    // what the user meant from what the screen showed, so an « add » of a
    // track already stored is simply a no-op.
    final hadTaps = _beforeLoad.isNotEmpty;
    for (final (path, added) in _beforeLoad) {
      if (added) {
        if (!list.contains(path)) list.add(path);
        final key = _keys[path];
        if (key != null) keys[path] = key;
      } else {
        list.remove(path);
        keys.remove(path);
      }
    }
    _beforeLoad.clear();
    _keys = keys;
    _loaded = true;
    state = List.unmodifiable(list);
    // Written only now, stored list included: never just the taps.
    if (hadTaps) await _save(keys: true);
  }

  bool isFavorite(String path) => state.contains(path);

  /// Adds [song] to the favourites, or removes it. Returns whether it is a
  /// favourite now.
  Future<bool> toggle(Song song) async {
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
    if (!_loaded) {
      // Saved by [_hydrate], merged with the stored list.
      _beforeLoad.add((path, now));
      return now;
    }
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
