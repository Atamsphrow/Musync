/// The user's favourite tracks, by file path, and where the list is kept.
///
/// Paths rather than MediaStore ids, like the other per-track stores (the
/// mismatch marks, the exclusions): an id can be reassigned when MediaStore
/// re-indexes, a path only changes when the file moves.
///
/// And when it moves, the favourite follows: the app's own renames and
/// moves carry it over directly, and a rename or move made elsewhere (a
/// file manager, another app) is found again at the next scan, from what
/// the favourite was the last time the library listed it — see
/// [FavoriteKey] and [reconcileFavorites].
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a favourite was the last time the library listed it: enough to
/// recognise the same track at another path.
@immutable
class FavoriteKey {
  /// MediaStore id. Android keeps the row — and the id — when a file is
  /// renamed or moved on the same storage, so this is the first clue.
  final int id;
  final String title;
  final String artist;

  /// Track length in milliseconds.
  final int durationMs;

  const FavoriteKey({
    required this.id,
    required this.title,
    required this.artist,
    required this.durationMs,
  });

  factory FavoriteKey.of(Song song) => FavoriteKey(
    id: song.id,
    title: song.title,
    artist: song.artist,
    durationMs: song.duration,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'duration': durationMs,
  };

  static FavoriteKey? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    final artist = raw['artist'];
    final duration = raw['duration'];
    if (id is! int || title is! String || artist is! String) return null;
    if (duration is! int) return null;
    return FavoriteKey(
      id: id,
      title: title,
      artist: artist,
      durationMs: duration,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FavoriteKey &&
      other.id == id &&
      other.title == title &&
      other.artist == artist &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(id, title, artist, durationMs);
}

/// [favorites] with every favourite whose file was renamed or moved
/// outside the app put back on its track, and the [FavoriteKey] of each
/// favourite the library lists now.
///
/// A favourite missing from [songs] follows a track only when its old file
/// is really gone ([fileExists] false — not just in an excluded folder) and
/// the track is clearly the same one, never already a favourite:
/// * the same MediaStore id and the same title (an id alone could have been
///   reassigned to another file by a re-index);
/// * failing that, the one track with the same title, artist and length
///   (within 2 s) — none or several, and the favourite waits, unchanged.
///
/// Order is kept: a favourite that moves keeps its place in the list.
/// Pure, for the notifier and its tests.
({List<String> favorites, Map<String, FavoriteKey> keys}) reconcileFavorites({
  required List<String> favorites,
  required Map<String, FavoriteKey> keys,
  required List<Song> songs,
  required bool Function(String path) fileExists,
}) {
  final byPath = {for (final song in songs) song.filePath: song};
  final taken = favorites.toSet();
  final result = <String>[];
  final newKeys = <String, FavoriteKey>{};
  for (final path in favorites) {
    final song = byPath[path];
    if (song != null) {
      result.add(path);
      newKeys[path] = FavoriteKey.of(song);
      continue;
    }
    final key = keys[path];
    final found = key == null || fileExists(path)
        ? null
        : _findMoved(key, songs, taken);
    if (found == null) {
      // Kept as it is: it comes back if the file does.
      result.add(path);
      if (key != null) newKeys[path] = key;
      continue;
    }
    taken.add(found.filePath);
    result.add(found.filePath);
    newKeys[found.filePath] = FavoriteKey.of(found);
  }
  return (favorites: result, keys: newKeys);
}

String _normalized(String s) => s.trim().toLowerCase();

Song? _findMoved(FavoriteKey key, List<Song> songs, Set<String> taken) {
  final title = _normalized(key.title);
  if (title.isEmpty) return null;
  final candidates = [
    for (final song in songs)
      if (!taken.contains(song.filePath) && _normalized(song.title) == title)
        song,
  ];
  for (final song in candidates) {
    if (song.id == key.id) return song;
  }
  final artist = _normalized(key.artist);
  final same = [
    for (final song in candidates)
      if (_normalized(song.artist) == artist &&
          (song.duration - key.durationMs).abs() <= 2000)
        song,
  ];
  return same.length == 1 ? same.single : null;
}

class FavoritesStore {
  /// SharedPreferences key holding the favourites, oldest first.
  static const String prefsKey = 'favorite_songs';

  /// Tests inject preferences seeded with `setMockInitialValues`.
  final SharedPreferences? prefsOverride;

  const FavoritesStore({this.prefsOverride});

  Future<SharedPreferences> _prefs() async =>
      prefsOverride ?? await SharedPreferences.getInstance();

  /// The stored paths, oldest first, without blanks or duplicates. Empty on
  /// any failure: unreadable favourites must never stop the app.
  Future<List<String>> load() async {
    try {
      final raw = (await _prefs()).getStringList(prefsKey) ?? const <String>[];
      final seen = <String>{};
      return List.unmodifiable([
        for (final entry in raw)
          if (entry.trim().isNotEmpty && seen.add(entry.trim())) entry.trim(),
      ]);
    } catch (error, stack) {
      DebugLog.instance.error(
        'Favoris',
        'Favoris illisibles : liste vide appliquée',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  Future<void> save(List<String> paths) async =>
      (await _prefs()).setStringList(prefsKey, paths);

  /// SharedPreferences key holding the [FavoriteKey]s, by path, as JSON.
  /// Phone-specific (MediaStore ids): never exported.
  static const String keysPrefsKey = 'favorite_song_keys';

  /// The stored keys; empty on any failure — they only help find a moved
  /// favourite, losing them never loses one.
  Future<Map<String, FavoriteKey>> loadKeys() async {
    try {
      final raw = (await _prefs()).getString(keysPrefsKey);
      if (raw == null) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && FavoriteKey.fromJson(entry.value) != null)
            entry.key as String: FavoriteKey.fromJson(entry.value)!,
      };
    } catch (error) {
      DebugLog.instance.warning(
        'Favoris',
        'Repères des favoris illisibles : ignorés',
        error: error,
      );
      return const {};
    }
  }

  Future<void> saveKeys(Map<String, FavoriteKey> keys) async =>
      (await _prefs()).setString(
        keysPrefsKey,
        jsonEncode({
          for (final entry in keys.entries) entry.key: entry.value.toJson(),
        }),
      );
}
