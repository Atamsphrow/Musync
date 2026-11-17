/// What was listened to, and how often: the « Historique » view.
///
/// One entry per file path — the play count and the last time it counted.
/// Kept as a small JSON file next to the other app settings, written
/// atomically (see AtomicFile). Never in the audio files themselves.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:path_provider/path_provider.dart';

@immutable
class ListenEntry {
  final int count;

  /// When the last listen counted, in ms since the epoch.
  final int lastPlayedMs;

  const ListenEntry({required this.count, required this.lastPlayedMs});

  ListenEntry counted(int atMs) =>
      ListenEntry(count: count + 1, lastPlayedMs: atMs);

  Map<String, Object> toJson() => {'count': count, 'last': lastPlayedMs};

  static ListenEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final count = raw['count'];
    final last = raw['last'];
    if (count is! int || last is! int || count <= 0) return null;
    return ListenEntry(count: count, lastPlayedMs: last);
  }

  @override
  bool operator ==(Object other) =>
      other is ListenEntry &&
      other.count == count &&
      other.lastPlayedMs == lastPlayedMs;

  @override
  int get hashCode => Object.hash(count, lastPlayedMs);
}

class ListeningHistoryStore {
  /// Overridable so tests need no `path_provider`.
  final Directory? root;

  const ListeningHistoryStore({this.root});

  static const String _fileName = 'listening_history.json';

  Future<File> _file() async {
    final dir = root ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// Empty on any failure: a history that cannot be read costs the history,
  /// never playback.
  Future<Map<String, ListenEntry>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const {};
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return const {};
      return {
        for (final entry in raw.entries)
          if (entry.key is String && ListenEntry.fromJson(entry.value) != null)
            (entry.key as String): ListenEntry.fromJson(entry.value)!,
      };
    } catch (error, stack) {
      DebugLog.instance.error(
        'Historique',
        'Historique d’écoute illisible : historique vide',
        error: error,
        stackTrace: stack,
      );
      return const {};
    }
  }

  Future<void> save(Map<String, ListenEntry> entries) async =>
      AtomicFile.writeString(
        await _file(),
        jsonEncode({
          for (final entry in entries.entries) entry.key: entry.value.toJson(),
        }),
      );
}

/// How long a track must play before the listen counts: 30 seconds, or half
/// the track when it is shorter than a minute. A skip after the intro is
/// not a listen; a short interlude played through is.
Duration listenThreshold(Duration trackLength) {
  const cap = Duration(seconds: 30);
  if (trackLength <= Duration.zero) return cap;
  final half = trackLength ~/ 2;
  return half < cap ? half : cap;
}
