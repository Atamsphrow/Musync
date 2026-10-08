/// Individual files the library scan must skip, and where the list is kept.
///
/// Mirrors [ExcludedDirsStore], but for files: the match is EXACT, never a
/// prefix — excluding `/Musique/a.mp3` must not hide `/Musique/a.mp3x`.
library;

import 'package:musync/core/services/debug_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ExcludedFilesStore {
  /// SharedPreferences key holding the excluded files as a string list.
  static const String prefsKey = 'excluded_scan_files';

  /// Where the preferences come from. Production reads the real instance;
  /// tests inject one seeded with `SharedPreferences.setMockInitialValues`
  /// instead — the plugin has no channel in a unit test.
  final SharedPreferences? prefsOverride;

  const ExcludedFilesStore({this.prefsOverride});

  Future<SharedPreferences> _prefs() async =>
      prefsOverride ?? await SharedPreferences.getInstance();

  /// The stored list, normalised and sorted. Empty on any failure: a list
  /// that cannot be read must not stop the scan — it only costs the exclusion
  /// itself.
  Future<List<String>> load() async {
    try {
      final raw = (await _prefs()).getStringList(prefsKey) ?? const <String>[];
      final files = <String>{};
      for (final entry in raw) {
        final file = normalise(entry);
        if (file.isNotEmpty) files.add(file);
      }
      final sorted = files.toList()..sort();
      return List.unmodifiable(sorted);
    } catch (error, stack) {
      DebugLog.instance.error(
        'Bibliothèque',
        'Fichiers exclus illisibles : scan sans exclusion',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  /// Persists [files] after normalising each entry.
  Future<void> save(List<String> files) async {
    final clean = <String>{};
    for (final entry in files) {
      final file = normalise(entry);
      if (file.isNotEmpty) clean.add(file);
    }
    await (await _prefs()).setStringList(prefsKey, clean.toList()..sort());
  }

  /// Trims whitespace. Unlike folders, a file path never ends with a
  /// separator, so there is nothing else to strip.
  static String normalise(String raw) => raw.trim();

  /// Whether [filePath] is exactly one of [excluded].
  ///
  /// Exact comparison on the normalised, lower-cased form: external storage
  /// is usually FAT/exFAT, whose case the picker and MediaStore do not spell
  /// the same way. Never a prefix test — `/Musique/a.mp3` must not exclude
  /// `/Musique/a.mp3x`.
  static bool isExcluded(String filePath, List<String> excluded) {
    final path = normalise(filePath).toLowerCase();
    if (path.isEmpty) return false;
    for (final file in excluded) {
      if (file.toLowerCase() == path) return true;
    }
    return false;
  }
}
