/// Directories the library scan must skip, and where the list is kept.
library;

import 'package:musync/core/services/debug_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ExcludedDirsStore {
  /// SharedPreferences key holding the excluded directories as a string list.
  static const String prefsKey = 'excluded_scan_dirs';

  /// Where the preferences come from. Production reads the real instance;
  /// tests inject one seeded with `SharedPreferences.setMockInitialValues`
  /// instead — the plugin has no channel in a unit test.
  final SharedPreferences? prefsOverride;

  const ExcludedDirsStore({this.prefsOverride});

  Future<SharedPreferences> _prefs() async =>
      prefsOverride ?? await SharedPreferences.getInstance();

  /// The stored list, normalised and sorted. Empty on any failure: a list
  /// that cannot be read must not stop the scan — it only costs the exclusion
  /// itself.
  Future<List<String>> load() async {
    try {
      final raw = (await _prefs()).getStringList(prefsKey) ?? const <String>[];
      final dirs = <String>{};
      for (final entry in raw) {
        final dir = normalise(entry);
        if (dir.isNotEmpty) dirs.add(dir);
      }
      final sorted = dirs.toList()..sort();
      return List.unmodifiable(sorted);
    } catch (error, stack) {
      DebugLog.instance.error(
        'Bibliothèque',
        'Dossiers exclus illisibles : scan sans exclusion',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  /// Persists [dirs] after normalising each entry.
  Future<void> save(List<String> dirs) async {
    final clean = <String>{};
    for (final entry in dirs) {
      final dir = normalise(entry);
      if (dir.isNotEmpty) clean.add(dir);
    }
    await (await _prefs()).setStringList(prefsKey, clean.toList()..sort());
  }

  /// Trims whitespace and every trailing separator, keeping the root itself.
  ///
  /// MediaStore and the folder picker agree on `/`-separated absolute paths
  /// but not on whether the end carries one, and a prefix test needs one form.
  static String normalise(String raw) {
    var path = raw.trim();
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  /// Whether [filePath] sits under one of [excluded] (or is one of them).
  ///
  /// The prefix comparison is on the normalised form with a path-boundary
  /// check, so `/sdcard/Musique` excludes `/sdcard/Musique/a.mp3` but not
  /// `/sdcard/Musique2/a.mp3`. Case-insensitive: external storage is usually
  /// FAT/exFAT, whose case the picker and MediaStore do not spell the same way.
  static bool isExcluded(String filePath, List<String> excluded) {
    final path = normalise(filePath).toLowerCase();
    if (path.isEmpty) return false;
    for (final dir in excluded) {
      final prefix = dir.toLowerCase();
      if (prefix.isEmpty) continue;
      if (path == prefix || path.startsWith('$prefix/')) return true;
    }
    return false;
  }
}
