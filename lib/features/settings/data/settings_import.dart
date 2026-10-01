/// Import of a settings bundle previously written by [SettingsExporter].
///
/// The mirror of the export: reads the JSON, checks it really is a Musync
/// export, and writes the files back where the stores read them.
///
/// Secrets need care. An export made without "Inclure les clés API" carries
/// blanked keys, and applying those blanks as-is would wipe the keys already
/// on the phone. So a blank secret in the bundle keeps the value already
/// stored — providers are matched by id — and only a non-blank secret
/// replaces what is there.
library;

import 'dart:convert';
import 'dart:io';

import 'package:musync/core/app_info.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:musync/features/settings/data/settings_export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Files an import knows where to put back, and whether each one lives in the
/// documents directory (`true`) or the support directory (`false`).
///
/// A name that is not here is ignored, never written: the app must not drop
/// arbitrary files into its own directories on the word of a JSON file.
const Map<String, bool> _knownFiles = {
  'playback_settings.json': false,
  'ai_providers.json': false,
  'lyrics_sources.json': true,
};

/// The one file whose secrets are merged rather than replaced outright.
const String _aiProvidersFile = 'ai_providers.json';

/// Preferences an import may set. Unknown keys are dropped: an old or
/// hand-edited export must not be able to write preferences the app does not
/// know.
int? _validBubbleLines(Object? value) =>
    value is int && value >= 1 && value <= 3 ? value : null;

/// A file path is only useful when it points somewhere.
String? _validSongPath(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int? _validSongPosition(Object? value) =>
    value is int && value >= 0 ? value : null;

/// Thrown when the picked file is not a Musync settings export. The [message]
/// is shown to the user as-is, so it is written in French.
class ImportFormatException implements Exception {
  final String message;
  const ImportFormatException(this.message);

  @override
  String toString() => 'ImportFormatException: $message';
}

/// A bundle that passed validation, ready to apply.
class ImportBundle {
  /// What was inside `files`, keyed by file name.
  final Map<String, Object?> files;

  /// Validated preferences (`bubble_lines`, the last-played track and friends).
  /// Values are the ints and strings the export wrote.
  final Map<String, Object> preferences;

  /// When the bundle was exported, as written in the file.
  final String exportedAt;

  /// The app version that wrote the bundle.
  final String version;

  /// Whether the bundle carries real secrets or blanked ones.
  final bool includesSecrets;

  /// File names found in the bundle that are not settings files and were left
  /// out.
  final List<String> ignoredFiles;

  const ImportBundle({
    required this.files,
    required this.preferences,
    required this.exportedAt,
    required this.version,
    required this.includesSecrets,
    required this.ignoredFiles,
  });
}

/// What the apply step did, for the confirmation message.
class ImportReport {
  /// File names written, in the bundle's order.
  final List<String> appliedFiles;

  /// Preference keys written.
  final List<String> appliedPreferences;

  /// Blank secrets in the bundle for which the stored value was kept.
  final int secretsKept;

  /// Non-blank secrets taken from the bundle.
  final int secretsApplied;

  const ImportReport({
    required this.appliedFiles,
    required this.appliedPreferences,
    required this.secretsKept,
    required this.secretsApplied,
  });
}

class SettingsImporter {
  /// Where the stores keep their files (`getApplicationSupportDirectory`).
  final Directory supportDir;

  /// Where the lyrics-source list is kept (`getApplicationDocumentsDirectory`).
  final Directory documentsDir;

  const SettingsImporter({
    required this.supportDir,
    required this.documentsDir,
  });

  /// Reads [file] and validates it, without writing anything.
  ///
  /// Throws [ImportFormatException] with a user-facing message when the file
  /// is not a usable Musync export.
  Future<ImportBundle> parse(File file) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FileSystemException {
      throw const ImportFormatException('Fichier illisible.');
    } on FormatException {
      throw const ImportFormatException("Ce fichier n'est pas du JSON valide.");
    }

    if (decoded is! Map) {
      throw const ImportFormatException("Ce fichier n'est pas un export Musync.");
    }
    final bundle = Map<String, Object?>.from(decoded);
    if (bundle['app'] != AppInfo.name) {
      throw const ImportFormatException("Ce fichier n'est pas un export Musync.");
    }

    final rawFiles = bundle['files'];
    if (rawFiles != null && rawFiles is! Map) {
      throw const ImportFormatException('Contenu de l\u2019export illisible.');
    }
    final files = <String, Object?>{};
    final ignored = <String>[];
    for (final entry in (rawFiles as Map? ?? const {}).entries) {
      final name = '${entry.key}';
      if (!_knownFiles.containsKey(name)) {
        ignored.add(name);
        continue;
      }
      if (entry.value is! Map && entry.value is! List) {
        throw ImportFormatException('Le réglage « $name » est illisible.');
      }
      files[name] = entry.value;
    }
    if (files.isEmpty) {
      throw const ImportFormatException(
        'Cet export ne contient aucun réglage connu.',
      );
    }

    final preferences = <String, Object>{};
    final rawPrefs = bundle['preferences'];
    if (rawPrefs is Map) {
      final lines = _validBubbleLines(rawPrefs['bubble_lines']);
      if (lines != null) preferences['bubble_lines'] = lines;
      final path = _validSongPath(rawPrefs['last_song_path']);
      if (path != null) preferences['last_song_path'] = path;
      final position = _validSongPosition(rawPrefs['last_song_position_ms']);
      if (position != null) preferences['last_song_position_ms'] = position;
    }

    return ImportBundle(
      files: files,
      preferences: preferences,
      exportedAt: '${bundle['exportedAt'] ?? ''}',
      version: '${bundle['version'] ?? ''}',
      includesSecrets: bundle['includesSecrets'] == true,
      ignoredFiles: ignored,
    );
  }

  /// Writes a parsed [bundle] back to the stores and preferences.
  ///
  /// Files are written atomically, like the stores do themselves. For the AI
  /// providers, blank secrets keep the stored values (see the library doc).
  ///
  /// The whole file set is applied atomically: every current file is read
  /// first, and if any write fails the ones already replaced are restored,
  /// so a failed import never leaves half the settings from the bundle and
  /// half from before.
  Future<ImportReport> apply(ImportBundle bundle, SharedPreferences prefs) async {
    final appliedFiles = <String>[];
    var secretsKept = 0;
    var secretsApplied = 0;

    // Resolve every target and prepare every new content before touching
    // the disk, so a validation failure cannot leave partial writes behind.
    final pending = <({File file, String content, String name})>[];
    for (final entry in bundle.files.entries) {
      final dir = _knownFiles[entry.key]! ? documentsDir : supportDir;
      var content = entry.value;
      if (entry.key == _aiProvidersFile) {
        final merged = await _mergeSecrets(entry.key, dir, content);
        content = merged.node;
        secretsKept += merged.kept;
        secretsApplied += merged.applied;
      }
      _validateSettingsFile(entry.key, content);
      pending.add((
        file: File('${dir.path}${Platform.pathSeparator}${entry.key}'),
        content: const JsonEncoder.withIndent('  ').convert(content),
        name: entry.key,
      ));
    }

    // Back up what is there now, so a failed write can be rolled back.
    final backups = <File, String?>{};
    for (final p in pending) {
      try {
        backups[p.file] =
            await p.file.exists() ? await p.file.readAsString() : null;
      } catch (_) {
        backups[p.file] = null;
      }
    }

    try {
      for (final p in pending) {
        await AtomicFile.writeString(p.file, p.content);
        appliedFiles.add(p.name);
      }
    } catch (e) {
      // Roll back: restore every file to what it was before the import.
      for (final entry in backups.entries) {
        try {
          final previous = entry.value;
          if (previous == null) {
            if (await entry.key.exists()) await entry.key.delete();
          } else {
            await AtomicFile.writeString(entry.key, previous);
          }
        } catch (_) {
          // Best effort — the original error is the one that matters.
        }
      }
      throw ImportFormatException(
        "L'import a échoué et les réglages ont été restaurés.",
      );
    }

    final appliedPrefs = <String>[];
    for (final entry in bundle.preferences.entries) {
      final value = entry.value;
      if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is String) {
        await prefs.setString(entry.key, value);
      } else {
        continue;
      }
      appliedPrefs.add(entry.key);
    }

    return ImportReport(
      appliedFiles: appliedFiles,
      appliedPreferences: appliedPrefs,
      secretsKept: secretsKept,
      secretsApplied: secretsApplied,
    );
  }

  /// Rejects a settings file whose structure the app cannot read back.
  ///
  /// A hand-edited or corrupted export must fail loudly here rather than
  /// silently wiping the user's providers with a file the store will parse
  /// as "no valid providers".
  void _validateSettingsFile(String name, Object? content) {
    if (name == _aiProvidersFile) {
      if (content is! Map) {
        throw const ImportFormatException(
          'Le fichier des fournisseurs IA est illisible.',
        );
      }
      final providers = content['providers'];
      if (providers is! List) {
        throw const ImportFormatException(
          'Le fichier des fournisseurs IA est illisible.',
        );
      }
      const validKinds = {'gemini', 'openAiCompatible'};
      for (final p in providers) {
        if (p is! Map) {
          throw const ImportFormatException(
            'Le fichier des fournisseurs IA contient un fournisseur illisible.',
          );
        }
        final id = p['id'];
        final providerName = p['name'];
        final kind = p['kind'];
        if (id is! String ||
            id.isEmpty ||
            providerName is! String ||
            providerName.isEmpty ||
            kind is! String ||
            !validKinds.contains(kind)) {
          throw const ImportFormatException(
            'Le fichier des fournisseurs IA contient un fournisseur illisible.',
          );
        }
      }
    }
  }

  /// The AI providers file with blank secrets filled back from the stored
  /// file, so importing an export made without keys does not wipe them.
  ///
  /// Providers are matched by `id`; a provider the stored file does not know
  /// keeps the bundle's values as-is.
  Future<({Object? node, int kept, int applied})> _mergeSecrets(
    String fileName,
    Directory dir,
    Object? imported,
  ) async {
    Object? current;
    try {
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      if (await file.exists()) {
        current = jsonDecode(await file.readAsString());
      }
    } catch (_) {
      // Unreadable stored file: nothing to merge with, the bundle wins.
      current = null;
    }

    var kept = 0;
    var applied = 0;

    Object? merge(Object? imp, Object? cur) {
      if (imp is Map && cur is Map) {
        final out = <String, Object?>{};
        for (final entry in imp.entries) {
          final key = '${entry.key}';
          final impValue = entry.value;
          final curValue = cur[entry.key];
          if (secretFieldName.hasMatch(key) && impValue is String) {
            if (impValue.isEmpty && curValue is String && curValue.isNotEmpty) {
              kept++;
              out[key] = curValue;
            } else {
              if (impValue.isNotEmpty) applied++;
              out[key] = impValue;
            }
          } else {
            out[key] = merge(impValue, curValue);
          }
        }
        return out;
      }
      if (imp is List && cur is List) {
        return [for (final item in imp) merge(item, _matchById(item, cur))];
      }
      return imp;
    }

    return (node: merge(imported, current), kept: kept, applied: applied);
  }

  /// The stored list item with the same `id` as [item], or null. Items without
  /// an id never match: merging by position would pair up providers that have
  /// nothing to do with each other once the order changed.
  static Object? _matchById(Object? item, List<Object?> current) {
    if (item is Map) {
      final id = item['id'];
      if (id is String) {
        for (final candidate in current) {
          if (candidate is Map && candidate['id'] == id) return candidate;
        }
      }
    }
    return null;
  }
}
