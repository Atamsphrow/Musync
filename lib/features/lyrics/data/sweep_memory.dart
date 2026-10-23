import 'dart:convert';
import 'dart:io';

import 'package:musync/core/utils/atomic_file.dart';
import 'package:path_provider/path_provider.dart';

/// Remembers, across launches, the tracks the background sweep
/// searched and CONFIRMEDLY found nothing for, so the next launch
/// (and the daily headless worker) skips them for a while instead of
/// re-querying the network — and the AI fallback — for every one of
/// them on every single launch.
///
/// Only confirmed misses belong here: a network failure, a missing
/// write permission or a failed write must never be remembered, or a
/// passing outage would silence a track for the whole validity
/// window. [BackgroundLyricsService] is the only writer and marks a
/// miss only at the exact point where searches succeeded and no
/// match came back.
class SweepMemory {
  static const String _fileName = 'lyrics_sweep_misses.json';

  /// How long a confirmed miss stays believed. Lyrics databases grow;
  /// a fortnight is long enough to kill the launch-after-launch
  /// re-querying without writing a track off for good.
  static const Duration validity = Duration(days: 14);

  Map<String, int>? _misses; // path -> epoch ms of the last confirmed miss
  bool _dirty = false;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<Map<String, int>> _load() async {
    final cached = _misses;
    if (cached != null) return cached;
    final loaded = <String, int>{};
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is int) loaded['${entry.key}'] = value;
          }
        }
      }
    } catch (_) {
      // Unreadable memory = search again, which is what happened before.
    }
    return _misses = loaded;
  }

  /// Whether [filePath] was confirmed missed within [validity].
  Future<bool> recentlyMissed(String filePath) async {
    final at = (await _load())[filePath];
    if (at == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - at;
    return age >= 0 && age < validity.inMilliseconds;
  }

  /// Records a confirmed miss for [filePath]. Persisted by [save].
  Future<void> markMissed(String filePath) async {
    (await _load())[filePath] = DateTime.now().millisecondsSinceEpoch;
    _dirty = true;
  }

  /// Writes the memory out (atomically) if anything changed.
  Future<void> save() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      await AtomicFile.writeString(await _file(), jsonEncode(await _load()));
    } catch (_) {
      // Best effort: the cost of a failed save is searching again
      // next time — the pre-memory behaviour.
    }
  }
}
