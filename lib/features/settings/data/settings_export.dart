/// Export of the app's settings and configuration to a single JSON file.
///
/// The bundle holds the settings stores as they are on disk (playback, lyrics
/// sources, AI providers) plus the few values kept in SharedPreferences. It does
/// not hold tag backups (audio bytes, large, and tied to files on this phone),
/// the debug journal, or caches that rebuild themselves.
///
/// Secrets — API keys and tokens — are blanked unless the caller asks for them:
/// the file lands in a folder every app can read, and is the kind of thing that
/// gets sent to someone to explain a problem.
library;

import 'dart:convert';
import 'dart:io';

import 'package:musync/core/app_info.dart';
import 'package:musync/core/utils/atomic_file.dart';

/// Value a blanked secret is replaced with. The key stays, so the export still
/// shows that a provider was configured.
const String kExportRedacted = '';

/// Field names taken for secrets, wherever they appear in the JSON.
final RegExp _secretName = RegExp(
  r'api.?key|token|secret|authorization|password',
  caseSensitive: false,
);

/// Files of the bundle, and which directory each one lives in.
class _Source {
  final String fileName;
  final bool inDocuments;
  const _Source(this.fileName, {this.inDocuments = false});
}

const List<_Source> _sources = [
  _Source('playback_settings.json'),
  _Source('ai_providers.json'),
  _Source('lyrics_sources.json', inDocuments: true),
];

class SettingsExporter {
  /// Where the stores keep their files (`getApplicationSupportDirectory`).
  final Directory supportDir;

  /// Where the lyrics-source list is kept (`getApplicationDocumentsDirectory`).
  final Directory documentsDir;

  const SettingsExporter({
    required this.supportDir,
    required this.documentsDir,
  });

  /// The bundle as a JSON-encodable map.
  ///
  /// [preferences] are the SharedPreferences values worth carrying, already
  /// picked by the caller. Files that are missing are left out; files that exist
  /// but cannot be read are listed under `unreadable` rather than failing the
  /// whole export.
  Future<Map<String, Object?>> build({
    bool includeSecrets = false,
    Map<String, Object?> preferences = const {},
    DateTime? now,
  }) async {
    final files = <String, Object?>{};
    final unreadable = <String>[];

    for (final source in _sources) {
      final dir = source.inDocuments ? documentsDir : supportDir;
      final file = File('${dir.path}${Platform.pathSeparator}${source.fileName}');
      if (!await file.exists()) continue;
      try {
        final decoded = jsonDecode(await file.readAsString());
        files[source.fileName] = includeSecrets ? decoded : redact(decoded);
      } on FormatException {
        unreadable.add(source.fileName);
      } on FileSystemException {
        unreadable.add(source.fileName);
      }
    }

    return {
      'app': AppInfo.name,
      'version': AppInfo.version,
      'exportedAt': (now ?? DateTime.now()).toIso8601String(),
      'includesSecrets': includeSecrets,
      'files': files,
      'preferences': preferences,
      if (unreadable.isNotEmpty) 'unreadable': unreadable,
    };
  }

  /// Writes the bundle into [targetDir] and returns the file.
  ///
  /// The name carries the time, so an export never replaces an earlier one.
  Future<File> exportTo(
    Directory targetDir, {
    bool includeSecrets = false,
    Map<String, Object?> preferences = const {},
    DateTime? now,
  }) async {
    final moment = now ?? DateTime.now();
    final bundle = await build(
      includeSecrets: includeSecrets,
      preferences: preferences,
      now: moment,
    );

    await targetDir.create(recursive: true);
    final file = File(
      '${targetDir.path}${Platform.pathSeparator}'
      'musync-export-${_stamp(moment)}.json',
    );
    await AtomicFile.writeString(
      file,
      const JsonEncoder.withIndent('  ').convert(bundle),
    );
    return file;
  }

  /// A copy of [node] with every secret blanked, however deep it sits.
  static Object? redact(Object? node) {
    if (node is Map) {
      return {
        for (final entry in node.entries)
          '${entry.key}': _secretName.hasMatch('${entry.key}') &&
                  entry.value is String
              ? kExportRedacted
              : redact(entry.value),
      };
    }
    if (node is List) return [for (final item in node) redact(item)];
    return node;
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
