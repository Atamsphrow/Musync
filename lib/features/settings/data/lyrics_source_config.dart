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

  /// LyricsPlus (Apple Music timings): word-by-word when the catalogue
  /// has them, line-by-line otherwise. A single fixed endpoint, not
  /// self-hostable — the bundled entry is the only one there is.
  lyricsPlus,

  /// lrc.red (TTML lyrics): line timings when the catalogue has them,
  /// plain text otherwise, word timings as `<span>` when it has those.
  /// A single fixed endpoint, not self-hostable — the bundled entry is
  /// the only one there is.
  lrcRed,

  /// Kugou (KRC lyrics): word timings when the catalogue has them.
  /// A single fixed endpoint, not self-hostable — the bundled entry is
  /// the only one there is.
  kugou,

  /// Genius (plain text, scraped from the song page): the last resort.
  /// A single fixed endpoint, not self-hostable — the bundled entry is
  /// the only one there is.
  genius,

  /// NetEase Cloud Music (line-synced LRC). A single fixed endpoint,
  /// not self-hostable — the bundled entry is the only one there is.
  netEase,
}

/// One entry in the sources list.
@immutable
class LyricsSourceConfig {
  /// Stable identity. Separate from [name] so renaming an entry doesn't orphan
  /// its enabled flag or silently create a duplicate.
  final String id;

  final String name;

  /// Base URL of the source's API, without a trailing slash: an
  /// LRCLIB-shaped API for [LyricsSourceKind.lrclib], the `/get`
  /// endpoint root for [LyricsSourceKind.lyricsPlus], the root of
  /// `search.json` and `/s/` for [LyricsSourceKind.lrcRed].
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
    // Migration (L94) : lyrics.ovh est retiré. Une entrée stockée avec
    // `kind: "lyricsOvh"` — seul chemin qui pouvait encore le produire,
    // via un JSON forgé — est abandonnée (null) au lieu d'être relue :
    // le service n'est plus jamais interrogé. L'entrée disparaît du
    // fichier au prochain `save()`, qui réécrit la liste chargée.
    if (raw['kind'] == 'lyricsOvh') return null;
    // Same bar as the settings screen's validateBaseUrl: the file/import
    // path skips that UI check, so a forged entry must not smuggle a
    // scheme the network layer would then feed to Uri.parse('$baseUrl/get').
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

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

/// The bundled word-timed source. Always present, after LRCLIB.
const LyricsSourceConfig lyricsPlusDefault = LyricsSourceConfig(
  id: 'lyrics-plus',
  name: 'LyricsPlus',
  baseUrl: 'https://lyricsplus.binimum.org/v2/lyrics',
  isBuiltIn: true,
  kind: LyricsSourceKind.lyricsPlus,
);

/// The bundled TTML source. Always present, after LyricsPlus.
const LyricsSourceConfig lrcRedDefault = LyricsSourceConfig(
  id: 'lrc-red',
  name: 'lrc.red',
  baseUrl: 'https://lrc.red',
  isBuiltIn: true,
  kind: LyricsSourceKind.lrcRed,
);

/// The bundled KRC source. Always present, after lrc.red.
const LyricsSourceConfig kugouDefault = LyricsSourceConfig(
  id: 'kugou',
  name: 'Kugou',
  baseUrl: 'https://lyrics.kugou.com',
  isBuiltIn: true,
  kind: LyricsSourceKind.kugou,
);

/// The bundled Genius source. Always present, last: it is only asked
/// when no synced lyrics came back.
const LyricsSourceConfig geniusDefault = LyricsSourceConfig(
  id: 'genius',
  name: 'Genius',
  baseUrl: 'https://genius.com/api',
  isBuiltIn: true,
  kind: LyricsSourceKind.genius,
);

/// The bundled NetEase source. Always present, after Kugou and
/// before Genius (the fallback stays last).
const LyricsSourceConfig netEaseDefault = LyricsSourceConfig(
  id: 'netease',
  name: 'NetEase',
  baseUrl: 'https://music.163.com',
  isBuiltIn: true,
  kind: LyricsSourceKind.netEase,
);

/// Every bundled entry, in the order they are shown.
const List<LyricsSourceConfig> builtInSources = [
  lrclibDefault,
  lyricsPlusDefault,
  lrcRedDefault,
  kugouDefault,
  netEaseDefault,
  geniusDefault,
];

/// Reads and writes the sources list as JSON in the app's documents directory.
///
/// A file rather than `shared_preferences`: `path_provider` is already a
/// dependency and already builds, whereas every plugin added to this project so
/// far has cost a Gradle fight. A list of a handful of records does not justify
/// one.
class LyricsSourceStore {
  static const String _fileName = 'lyrics_sources.json';

  /// Where the file lives. Production reads the app's documents directory;
  /// tests inject a temporary file instead — `path_provider` has no plugin
  /// in a unit test.
  final Future<File> Function()? fileLocator;

  const LyricsSourceStore({this.fileLocator});

  Future<File> _file() async {
    final locator = fileLocator;
    if (locator != null) return locator();
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// The stored list, with the bundled entries guaranteed present and first.
  ///
  /// Any failure — no file yet, unreadable JSON, a truncated write — falls back
  /// to the default rather than throwing. The lyrics search has to keep working
  /// even if this file is nonsense.
  Future<List<LyricsSourceConfig>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return List.of(builtInSources);

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return List.of(builtInSources);

      final configs = <LyricsSourceConfig>[
        for (final entry in decoded) ?LyricsSourceConfig.fromJson(entry),
      ];
      return _withBuiltIn(configs);
    } catch (error, stack) {
      // Falling back to the bundled sources keeps the search working, which
      // is the point — but any mirror the user added has silently stopped being
      // queried, and they would have no way of telling.
      DebugLog.instance.error(
        'Réglages',
        'Liste des sources illisible : les sources intégrées seront utilisées',
        error: error,
        stackTrace: stack,
      );
      return List.of(builtInSources);
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

  @visibleForTesting
  static List<LyricsSourceConfig> withBuiltInForTest(
    List<LyricsSourceConfig> configs,
  ) => _withBuiltIn(configs);

  /// Puts the bundled entries back at the head of the list, keeping whatever
  /// enabled flag the user had set on each.
  ///
  /// Also how a new bundled source reaches someone who already has a saved
  /// file: it is simply absent from theirs, and appears here on the next read.
  ///
  /// Migration: lyrics.ovh used to be bundled, then a one-tap preset. Both
  /// are gone now: any stored entry with its id is dropped, so the
  /// unreliable service is never queried.
  static List<LyricsSourceConfig> _withBuiltIn(
    List<LyricsSourceConfig> configs,
  ) {
    final builtInIds = builtInSources.map((c) => c.id).toSet();
    final withoutLegacyOvh = configs
        .where((c) => c.id != 'lyrics-ovh')
        .toList();

    return [
      for (final bundled in builtInSources)
        () {
          final stored = withoutLegacyOvh
              .where((c) => c.id == bundled.id)
              .firstOrNull;
          // Only the flag is the user's to keep: name, URL and kind are fixed
          // for a bundled entry, so a corrupted file cannot repoint it.
          return stored == null
              ? bundled
              : bundled.copyWith(enabled: stored.enabled);
        }(),
      ...withoutLegacyOvh.where((c) => !builtInIds.contains(c.id)),
    ];
  }
}

// Private: the SDK already provides `Iterable.firstOrNull` (Dart 3.13),
// and a public extension with the same name collides with
// `package:collection`'s the moment a file imports both. The two uses in
// this file resolve to the SDK member.
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
