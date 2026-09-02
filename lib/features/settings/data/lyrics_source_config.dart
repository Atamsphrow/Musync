/// User-configurable lyrics sources (plan P5), and where they are kept.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:path_provider/path_provider.dart';

/// What kind of service an entry speaks to.
///
/// Stored alongside the entry rather than inferred from its URL: guessing from
/// a hostname would break the moment someone self-hosts either one. Records
/// written before this field existed read back as [lrclib], which is correct —
/// it was the only kind there was, and the only kind a user can add.
enum LyricsSourceKind {
  /// Anything speaking LRCLIB's API: the bundled instance, a mirror, or a
  /// self-hosted copy. Returns timed lyrics.
  lrclib,

  /// api.lyrics.ovh. Plain words, never timings, and nothing to configure.
  lyricsOvh,
}

/// One entry in the sources list.
@immutable
class LyricsSourceConfig {
  /// Stable identity. Separate from [name] so renaming an entry doesn't orphan
  /// its enabled flag or silently create a duplicate.
  final String id;

  final String name;

  /// Base URL of an LRCLIB-shaped API, without a trailing slash.
  final String baseUrl;

  final bool enabled;

  /// A bundled entry. Can be switched off, never deleted or repointed —
  /// leaving no way back to a working default would be a trap.
  final bool isBuiltIn;

  final LyricsSourceKind kind;

  const LyricsSourceConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.enabled = true,
    this.isBuiltIn = false,
    this.kind = LyricsSourceKind.lrclib,
  });

  LyricsSourceConfig copyWith({String? name, String? baseUrl, bool? enabled}) =>
      LyricsSourceConfig(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        enabled: enabled ?? this.enabled,
        isBuiltIn: isBuiltIn,
        kind: kind,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'enabled': enabled,
    'isBuiltIn': isBuiltIn,
    'kind': kind.name,
  };

  /// Returns null for an entry that can't be read, so one bad record doesn't
  /// take the whole list — and the user's other sources — down with it.
  static LyricsSourceConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final baseUrl = raw['baseUrl'];
    if (id is! String || name is! String || baseUrl is! String) return null;
    if (id.isEmpty || baseUrl.isEmpty) return null;

    return LyricsSourceConfig(
      id: id,
      name: name,
      baseUrl: baseUrl,
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
      isBuiltIn: raw['isBuiltIn'] == true,
      kind:
          LyricsSourceKind.values
              .where((k) => k.name == raw['kind'])
              .firstOrNull ??
          LyricsSourceKind.lrclib,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LyricsSourceConfig &&
          other.id == id &&
          other.name == name &&
          other.baseUrl == baseUrl &&
          other.enabled == enabled &&
          other.isBuiltIn == isBuiltIn &&
          other.kind == kind;

  @override
  int get hashCode => Object.hash(id, name, baseUrl, enabled, isBuiltIn, kind);
}

/// The bundled timed-lyrics source. Always present, always first.
const LyricsSourceConfig lrclibDefault = LyricsSourceConfig(
  id: 'lrclib',
  name: 'LRCLIB',
  baseUrl: 'https://lrclib.net/api',
  isBuiltIn: true,
);

/// The bundled plain-lyrics fallback.
///
/// On by default. It only ever speaks up when it has something, it ranks below
/// any timed result, and what it returns is exactly what the sync editor needs
/// to work on — so a track LRCLIB has never heard of stops being a dead end.
const LyricsSourceConfig lyricsOvhDefault = LyricsSourceConfig(
  id: 'lyrics-ovh',
  name: 'lyrics.ovh',
  baseUrl: 'https://api.lyrics.ovh',
  isBuiltIn: true,
  kind: LyricsSourceKind.lyricsOvh,
);

/// Every bundled entry, in the order they are shown.
const List<LyricsSourceConfig> builtInSources = [
  lrclibDefault,
  lyricsOvhDefault,
];

/// Reads and writes the sources list as JSON in the app's documents directory.
///
/// A file rather than `shared_preferences`: `path_provider` is already a
/// dependency and already builds, whereas every plugin added to this project so
/// far has cost a Gradle fight. A list of a handful of records does not justify
/// one.
class LyricsSourceStore {
  static const String _fileName = 'lyrics_sources.json';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// The stored list, with the built-in entry guaranteed present and first.
  ///
  /// Any failure — no file yet, unreadable JSON, a truncated write — falls back
  /// to the default rather than throwing. The lyrics search has to keep working
  /// even if this file is nonsense.
  Future<List<LyricsSourceConfig>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [lrclibDefault];

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [lrclibDefault];

      final configs = <LyricsSourceConfig>[
        for (final entry in decoded) ?LyricsSourceConfig.fromJson(entry),
      ];
      return _withBuiltIn(configs);
    } catch (error, stack) {
      // Falling back to LRCLIB alone keeps the search working, which is the
      // point — but any mirror the user added has silently stopped being
      // queried, and they would have no way of telling.
      DebugLog.instance.error(
        'Réglages',
        'Liste des sources illisible : seule LRCLIB sera interrogée',
        error: error,
        stackTrace: stack,
      );
      return const [lrclibDefault];
    }
  }

  /// Atomic, and serialised per file — see [AtomicFile].
  ///
  /// The bundled entries are put back before writing, not only when reading:
  /// what is on disk should be what the app believes, so a file inspected by
  /// hand is not missing rows the app silently adds back.
  Future<void> save(List<LyricsSourceConfig> configs) async {
    await AtomicFile.writeString(
      await _file(),
      jsonEncode([for (final c in _withBuiltIn(configs)) c.toJson()]),
    );
  }

  /// Puts the bundled entries back at the head of the list, keeping whatever
  /// enabled flag the user had set on each.
  ///
  /// Also how a new bundled source reaches someone who already has a saved
  /// file: it is simply absent from theirs, and appears here on the next read.
  static List<LyricsSourceConfig> _withBuiltIn(
    List<LyricsSourceConfig> configs,
  ) {
    final builtInIds = builtInSources.map((c) => c.id).toSet();

    return [
      for (final bundled in builtInSources)
        () {
          final stored = configs.where((c) => c.id == bundled.id).firstOrNull;
          // Only the flag is the user's to keep: name, URL and kind are fixed
          // for a bundled entry, so a corrupted file cannot repoint it.
          return stored == null
              ? bundled
              : bundled.copyWith(enabled: stored.enabled);
        }(),
      ...configs.where((c) => !builtInIds.contains(c.id)),
    ];
  }
}

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
