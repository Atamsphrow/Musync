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

import 'dart:typed_data';

import 'package:musync/core/app_info.dart';
import 'package:musync/core/id3/tag_backup.dart';
import 'package:musync/features/settings/data/lyrics_source_config.dart';
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
  'lyrics_appearance.json': false,
  'ai_providers.json': false,
  'lyrics_sources.json': true,
};

/// The one file whose secrets are merged rather than replaced outright.
const String _aiProvidersFile = 'ai_providers.json';

/// The lyrics-sources file, validated entry by entry (see
/// [_validateSettingsFile]).
const String _sourcesFile = 'lyrics_sources.json';

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

/// The tag-backup history of a bundle, validated and ready to apply.
///
/// [entries] are the index rows whose backup bytes are present; [skipped]
/// names the index rows whose bytes were missing from the bundle (listed at
/// export time under `missing`/`unreadable`). Skipped rows are left out of
/// the restored index rather than restored as dangling references.
class TagBackupImport {
  final List<TagBackup> entries;
  final Map<String, Uint8List> files;
  final List<String> skipped;

  const TagBackupImport({
    required this.entries,
    required this.files,
    required this.skipped,
  });

  bool get isEmpty => entries.isEmpty;
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

  /// The tag-backup history, when the bundle carries one. Null means the
  /// bundle has no `tagBackups` section and the history on the phone is left
  /// untouched.
  final TagBackupImport? tagBackups;

  const ImportBundle({
    required this.files,
    required this.preferences,
    required this.exportedAt,
    required this.version,
    required this.includesSecrets,
    required this.ignoredFiles,
    required this.tagBackups,
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

  /// Tag backups restored from the bundle's history.
  final int tagBackupsRestored;

  /// Index rows skipped for lack of backup bytes in the bundle.
  final List<String> tagBackupsSkipped;

  const ImportReport({
    required this.appliedFiles,
    required this.appliedPreferences,
    required this.secretsKept,
    required this.secretsApplied,
    required this.tagBackupsRestored,
    required this.tagBackupsSkipped,
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
      // A trapped JSON of hundreds of MB would OOM the isolate in readAsString
      // + jsonDecode (UTF-16 string, then a 3-5x object graph). A legitimate
      // export with history tops out at a few MB — refuse early instead.
      if (await file.length() > 32 * 1024 * 1024) {
        throw const ImportFormatException(
          'Fichier trop volumineux pour être un export Musync.',
        );
      }
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
      tagBackups: _parseTagBackups(bundle['tagBackups']),
    );
  }

  /// Validates the bundle's tag-backup history without writing anything.
  ///
  /// Returns null when the bundle carries no history (the phone's is left
  /// untouched). Throws [ImportFormatException] when the section is present
  /// but malformed — a corrupt history must fail loudly rather than wipe the
  /// current one with half a restore.
  TagBackupImport? _parseTagBackups(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw const ImportFormatException(
        "L'historique des sauvegardes est illisible.",
      );
    }
    final rawIndex = raw['index'];
    if (rawIndex is! List) {
      throw const ImportFormatException(
        "L'historique des sauvegardes est illisible.",
      );
    }
    final rawFiles = raw['files'];
    if (rawFiles is! Map) {
      throw const ImportFormatException(
        "L'historique des sauvegardes est illisible.",
      );
    }

    // File data first: every key must be a safe name with decodable bytes.
    // Anything else is corruption, not history.
    final files = <String, Uint8List>{};
    for (final entry in rawFiles.entries) {
      final name = '${entry.key}';
      if (!isSafeBackupName(name)) {
        throw const ImportFormatException(
          "L'historique des sauvegardes est illisible.",
        );
      }
      final encoded = entry.value;
      if (encoded is! String) {
        throw ImportFormatException(
          'Sauvegarde « $name » corrompue dans le fichier.',
        );
      }
      try {
        files[name] = base64Decode(encoded);
      } catch (_) {
        throw ImportFormatException(
          'Sauvegarde « $name » corrompue dans le fichier.',
        );
      }
    }

    // Then the index: every row must parse and name a safe file.
    final entries = <TagBackup>[];
    final skipped = <String>[];
    for (final rawEntry in rawIndex) {
      final backup = TagBackup.fromJson(rawEntry);
      if (backup == null || !isSafeBackupName(backup.storedAs)) {
        throw const ImportFormatException(
          "L'historique des sauvegardes est illisible.",
        );
      }
      if (files.containsKey(backup.storedAs)) {
        entries.add(backup);
      } else {
        skipped.add(backup.storedAs);
      }
    }
    return TagBackupImport(entries: entries, files: files, skipped: skipped);
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

    // The history replaces the phone's tag backups as part of the same atomic
    // unit: it runs inside this try so that a failure also rolls back the
    // settings files above (_applyTagBackups rolls the history back itself).
    int restoredBackups = 0;
    try {
      for (final p in pending) {
        await AtomicFile.writeString(p.file, p.content);
        appliedFiles.add(p.name);
      }
      final tagBackups = bundle.tagBackups;
      if (tagBackups != null) {
        restoredBackups = await _applyTagBackups(tagBackups);
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
      // _applyTagBackups throws ImportFormatException with its own specific
      // message (and has already rolled the history back); keep it as-is.
      if (e is ImportFormatException) rethrow;
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
      tagBackupsRestored: restoredBackups,
      tagBackupsSkipped: bundle.tagBackups?.skipped ?? const [],
    );
  }

  /// Restores the bundle's tag-backup history, replacing the phone's.
  ///
  /// Atomic like the settings files: the current index is read first, and if
  /// any write fails the files written so far are removed again and the old
  /// index put back, so a failed import never leaves half a history behind.
  /// Returns the number of backups restored.
  Future<int> _applyTagBackups(TagBackupImport history) async {
    final dir = Directory(
      '${supportDir.path}${Platform.pathSeparator}tag_backups',
    );
    await dir.create(recursive: true);
    final indexFile = File(
      '${dir.path}${Platform.pathSeparator}index.json',
    );

    // Snapshot what is there now for the rollback.
    String? previousIndex;
    try {
      previousIndex =
          await indexFile.exists() ? await indexFile.readAsString() : null;
    } catch (_) {
      previousIndex = null;
    }
    final before = <String>{};
    // Bytes of the files this import is about to overwrite: a failed restore
    // must put the originals back, not just leave the new bytes under the
    // restored index.
    final overwritten = <String, Uint8List>{};
    try {
      await for (final entity in dir.list()) {
        if (entity is File) {
          before.add(entity.path.split(Platform.pathSeparator).last);
        }
      }
      for (final entry in history.entries) {
        if (before.contains(entry.storedAs)) {
          try {
            final file = File(
              '${dir.path}${Platform.pathSeparator}${entry.storedAs}',
            );
            if (await file.exists()) {
              overwritten[entry.storedAs] = await file.readAsBytes();
            }
          } catch (_) {
            // Best effort; the rollback below degrades gracefully.
          }
        }
      }
    } catch (_) {
      // Best effort; the rollback below degrades gracefully.
    }

    final written = <String>[];
    try {
      for (final entry in history.entries) {
        final bytes = history.files[entry.storedAs]!;
        final file = File(
          '${dir.path}${Platform.pathSeparator}${entry.storedAs}',
        );
        await AtomicFile.writeBytes(file, bytes);
        written.add(entry.storedAs);
      }
      await AtomicFile.writeString(
        indexFile,
        const JsonEncoder.withIndent('  ').convert(
          [for (final entry in history.entries) entry.toJson()],
        ),
      );
      return history.entries.length;
    } catch (_) {
      // Roll back: remove what this import wrote, restore the old index,
      // and put back the original bytes of the files it overwrote.
      for (final name in written) {
        if (before.contains(name)) continue;
        try {
          final file = File(
            '${dir.path}${Platform.pathSeparator}$name',
          );
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      for (final entry in overwritten.entries) {
        try {
          await AtomicFile.writeBytes(
            File('${dir.path}${Platform.pathSeparator}${entry.key}'),
            entry.value,
          );
        } catch (_) {}
      }
      try {
        if (previousIndex == null) {
          if (await indexFile.exists()) await indexFile.delete();
        } else {
          await AtomicFile.writeString(indexFile, previousIndex);
        }
      } catch (_) {}
      throw const ImportFormatException(
        "L'import de l'historique a échoué et les sauvegardes ont été "
        'restaurées.',
      );
    }
  }

  /// Rejects a settings file whose structure the app cannot read back.
  ///
  /// A hand-edited or corrupted export must fail loudly here rather than
  /// silently wiping the user's sources with a file the store will parse as
  /// "no usable sources". Individual malformed entries are tolerated, exactly
  /// like [LyricsSourceStore.load] does (?fromJson) — only a file that is not
  /// a list at all is rejected.
  void _validateSettingsFile(String name, Object? content) {
    if (name == _sourcesFile) {
      if (content is! List) {
        throw const ImportFormatException(
          'Le fichier des sources de paroles est illisible.',
        );
      }
    }
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
