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
  Future<Map<String, String>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return {};
      final out = <String, String>{};
      for (final entry in decoded.entries) {
        if (entry.key is String) {
          // Old cache stored int mtimes; new format is "mtime:size".
          // An int entry never matches a "mtime:size" key, so it naturally
          // forces a re-read — exactly what we want after the format change.
          // Anything else (null, list, object from a corrupt file) is not a
          // mtime at all: ignored, so the file is re-read and the entry
          // overwritten with the real key on the next save.
          final value = entry.value;
          if (value is String) {
            out[entry.key as String] = value;
          } else if (value is int) {
            out[entry.key as String] = '$value';
          }
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Best effort: losing the record just means the next refresh re-reads more
  /// tags than strictly needed — never lost music, never a crash.
  Future<void> save(Map<String, String> mtimes) async {
    try {
      await AtomicFile.writeString(await _file(), jsonEncode(mtimes));
    } catch (_) {
      // Nothing to do; the next refresh rebuilds the record.
    }
  }
}
