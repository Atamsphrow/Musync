/// The user's favourite tracks, by file path, and where the list is kept.
///
/// Paths rather than MediaStore ids, like the other per-track stores (the
/// mismatch marks, the exclusions): an id can be reassigned when MediaStore
/// re-indexes, a path only changes when the file moves.
library;

import 'package:musync/core/services/debug_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
