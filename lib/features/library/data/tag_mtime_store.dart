import 'dart:convert';
import 'dart:io';

import 'package:musync/core/utils/atomic_file.dart';
import 'package:path_provider/path_provider.dart';

/// Persists the mtime each audio file had the last time its tags were read.
///
/// A manual library refresh stats every file and re-reads the ID3 tag only
/// when the mtime moved. Without this record, every refresh would re-parse
/// every tag in the library just to find the one file an external editor
/// touched.
class TagMtimeStore {
  /// Overridable so tests need no `path_provider`.
  final Directory? root;

  const TagMtimeStore({this.root});

  static const String _fileName = 'tag_mtimes.json';

  Future<File> _file() async {
    final dir = root ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// Path → mtime in milliseconds since epoch. Empty — not an error — when
  /// nothing was ever recorded or the file can't be read.
  Future<Map<String, int>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return {};
      final out = <String, int>{};
      for (final entry in decoded.entries) {
        if (entry.key is String && entry.value is int) {
          out[entry.key as String] = entry.value as int;
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Best effort: losing the record just means the next refresh re-reads more
  /// tags than strictly needed — never lost music, never a crash.
  Future<void> save(Map<String, int> mtimes) async {
    try {
      await AtomicFile.writeString(await _file(), jsonEncode(mtimes));
    } catch (_) {
      // Nothing to do; the next refresh rebuilds the record.
    }
  }
}
