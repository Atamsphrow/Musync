/// Persists the playback state that should survive an app restart: the queue
/// (as file paths, in order), the current index in it, the shuffle and
/// repeat modes, and whether the bubble was active.
///
/// One JSON file in the app's documents directory, written atomically (see
/// [AtomicFile]): a whole-library queue is tens of kilobytes, and
/// SharedPreferences rewrites its entire XML file on every edit. Updates
/// merge into an in-memory copy, so the audio service and the bubble
/// controller can each save their own fields without clobbering the other's.
///
/// The last song's path and position stay in [LastSongStore] (shared
/// preferences): the settings import/export knows those keys, and the
/// restore matches the current song by path anyway.
library;

import 'dart:convert';
import 'dart:io';

import 'package:musync/core/utils/atomic_file.dart';
import 'package:path_provider/path_provider.dart';

/// The persisted playback state. All fields have safe defaults, so a missing
/// or half-written file reads as "nothing to restore" rather than throwing.
class PlaybackState {
  /// File paths of the queue, in order.
  final List<String> queuePaths;

  /// Index of the current song inside [queuePaths].
  final int index;

  final bool shuffle;

  /// 'off', 'all' or 'one', mirroring just_audio's LoopMode names.
  final String repeat;

  final bool bubbleActive;

  const PlaybackState({
    this.queuePaths = const [],
    this.index = 0,
    this.shuffle = false,
    this.repeat = 'off',
    this.bubbleActive = false,
  });
}

class PlaybackStateStore {
  static const String _fileName = 'playback_state.json';

  /// In-memory copy: every update merges into it, so two writers (the audio
  /// service, the bubble controller) never interleave a read-modify-write.
  static Map<String, Object?>? _memory;

  /// Where the file lives. Production reads the app's documents directory;
  /// tests inject a temporary file instead — `path_provider` has no plugin
  /// in a unit test.
  final Future<File> Function()? fileLocator;

  const PlaybackStateStore({this.fileLocator});

  Future<File> _file() async {
    final locator = fileLocator;
    if (locator != null) return locator();
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<Map<String, Object?>> _read() async {
    final cached = _memory;
    if (cached != null) return cached;
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          _memory = decoded.cast<String, Object?>();
          return _memory!;
        }
      }
    } catch (_) {
      // A corrupt file reads as empty; the next update overwrites it.
    }
    _memory = {};
    return _memory!;
  }

  /// Merges the given fields into the stored state. Null means "leave it".
  /// Never throws: persistence is best-effort, playback is not.
  Future<void> update({
    List<String>? queuePaths,
    int? index,
    bool? shuffle,
    String? repeat,
    bool? bubbleActive,
  }) async {
    final map = await _read();
    if (queuePaths != null) map['queue'] = queuePaths;
    if (index != null) map['index'] = index;
    if (shuffle != null) map['shuffle'] = shuffle;
    if (repeat != null) map['repeat'] = repeat;
    if (bubbleActive != null) map['bubbleActive'] = bubbleActive;
    try {
      await AtomicFile.writeString(await _file(), jsonEncode(map));
    } catch (_) {
      // The in-memory copy already has it; the next update retries the disk.
    }
  }

  Future<PlaybackState> load() async {
    final map = await _read();
    final queue = <String>[
      for (final p in (map['queue'] as List? ?? const []))
        if (p is String && p.isNotEmpty) p,
    ];
    var index = map['index'] is int ? map['index'] as int : 0;
    if (queue.isEmpty) {
      index = 0;
    } else {
      if (index < 0) index = 0;
      if (index >= queue.length) index = queue.length - 1;
    }
    final repeat = map['repeat'];
    return PlaybackState(
      queuePaths: queue,
      index: index,
      shuffle: map['shuffle'] == true,
      repeat: repeat == 'all' || repeat == 'one' ? repeat as String : 'off',
      bubbleActive: map['bubbleActive'] == true,
    );
  }

  /// Test hook: forget the in-memory copy so the next read hits the file.
  static void debugResetForTest() {
    _memory = null;
  }
}
