/// File-system confinement for AI tools accepting paths proposed by a model.
/// A destination may be inside a directory containing a scanned library song,
/// but not outside those directories or through a symlink. No implicit
/// permission to access arbitrary private/system files is granted.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

abstract final class LibraryPathGuard {
  /// Rejects ambiguous/relative paths and traversal before normalization.
  static bool isSafeAbsolute(String raw) =>
      p.isAbsolute(raw) &&
      !p.split(raw).contains('..') &&
      !p.split(raw).contains('.');

  /// Protects a path that will be read or created by an AI tool.
  /// Library files are passed as file paths, not editable root suggestions.
  static Future<bool> permits(
    String candidate,
    Iterable<String> libraryFiles,
  ) async {
    if (!isSafeAbsolute(candidate)) return false;
    final normalized = p.normalize(candidate);
    for (final source in libraryFiles) {
      if (!isSafeAbsolute(source)) continue;
      final root = p.dirname(p.normalize(source));
      if (normalized != root && !p.isWithin(root, normalized)) continue;
      // Existing symlinks *below* the permitted root can escape the library.
      // Check each part, including the target itself if it already exists.
      var current = root;
      final suffix = p.relative(normalized, from: root);
      final segments = suffix == '.' ? const <String>[] : p.split(suffix);
      var safe = true;
      for (final segment in segments) {
        current = p.join(current, segment);
        try {
          if (await FileSystemEntity.type(current, followLinks: false) ==
              FileSystemEntityType.link) {
            safe = false;
            break;
          }
        } on FileSystemException {
          safe = false;
          break;
        }
      }
      if (safe) return true;
    }
    return false;
  }
}
