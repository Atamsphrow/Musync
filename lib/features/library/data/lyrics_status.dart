/// What Musync knows about a track's lyrics — the axis the catalogue sorts on.
library;

import 'dart:convert';
import 'dart:io';

import 'package:musync/core/utils/atomic_file.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:path_provider/path_provider.dart';

/// The three states a track can be in, and the three tabs of the catalogue.
///
/// Ordered from least to most complete, which is also the order a track moves
/// through as the user works on it.
enum LyricsStatus {
  /// Neither USLT nor SYLT. Nothing to show while the track plays.
  none,

  /// USLT only: the words, with no timings.
  plain,

  /// SYLT present. Timed, and what the sync editor produces.
  synced,
}

/// Short label, for the catalogue's tabs where a count sits beside it.
String lyricsStatusLabel(LyricsStatus status) => switch (status) {
  LyricsStatus.none => 'Sans paroles',
  LyricsStatus.plain => 'Simples',
  LyricsStatus.synced => 'Synchronisées',
};

/// Full label, for tooltips and screen readers, where there is no tab header
/// nearby to supply the missing noun.
String lyricsStatusDescription(LyricsStatus status) => switch (status) {
  LyricsStatus.none => 'Sans paroles',
  LyricsStatus.plain => 'Paroles simples',
  LyricsStatus.synced => 'Paroles synchronisées',
};

/// Resolves [LyricsStatus] for files on disk, and remembers the answers.
///
/// Three things keep this affordable across a whole library, because the
/// catalogue needs an answer for every track before it can show its tabs:
///
///  * [Id3Reader.readLyricsFrames] walks frame headers and seeks past every
///    body it doesn't need, so a track's cover art is never read;
///  * answers are cached in memory, keyed by modification time as well as path,
///    so a file Musync itself has just written is re-read rather than served
///    stale — embedding lyrics is precisely what changes a track's status;
///  * the cache is written to disk, so a second launch does almost no I/O at
///    all.
class LyricsStatusScanner {
  final Map<String, _Entry> _cache = <String, _Entry>{};

  /// Where the cache is kept between launches.
  ///
  /// Without this, every launch re-read the whole library even though nothing
  /// had changed — the scan is cheap per track and never free, and a thousand
  /// of them is a visibly slow start. The modification time stored beside each
  /// status is what makes a stale entry detectable, so a file edited by another
  /// app is still picked up.
  static const String _cacheFileName = 'lyrics_status_cache.json';

  bool _loaded = false;
  bool _dirty = false;

  /// How many files to read at once.
  ///
  /// Unbounded `Future.wait` over a whole library opens one handle per track
  /// and competes with itself for the disk; a small window keeps the scan
  /// responsive without starving the UI isolate.
  static const int _concurrency = 8;

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_cacheFileName');
  }

  /// Reads the previous run's answers. Called once, before the first scan.
  ///
  /// Every failure is swallowed: a missing, truncated or nonsensical cache just
  /// means doing the work again, which is exactly what happened before the
  /// cache existed. It must never be the reason a library won't open.
  Future<void> _restore() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final file = await _cacheFile();
      if (!await file.exists()) return;

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;

      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final mtime = value['mtime'];
        final index = value['status'];
        if (mtime is! int || index is! int) continue;
        if (index < 0 || index >= LyricsStatus.values.length) continue;
        _cache['${entry.key}'] = _Entry(mtime, LyricsStatus.values[index]);
      }
    } catch (error) {
      // Clearing is right — a half-read cache is worse than none — but it means
      // the next launch re-opens all 1876 files, and "the app is slow to start
      // today" deserves a reason somewhere.
      _cache.clear();
      DebugLog.instance.warning(
        'Catalogue',
        'Cache des statuts illisible : la bibliothèque sera relue entièrement',
        error: error,
      );
    }
  }

  /// Writes the cache back, if anything changed since it was read.
  ///
  /// Temp file then rename, like every other write in this app: a run
  /// interrupted mid-save leaves the previous cache intact rather than a
  /// half-written file the next launch would throw away.
  Future<void> _persist() async {
    if (!_dirty) return;
    _dirty = false;

    try {
      await AtomicFile.writeString(
        await _cacheFile(),
        jsonEncode({
          for (final entry in _cache.entries)
            entry.key: {
              'mtime': entry.value.mtime,
              'status': entry.value.status.index,
            },
        }),
      );
    } catch (error) {
      // A cache that can't be written costs a slower next launch, nothing more.
      // Once per session: if the directory is unwritable it will fail on every
      // sweep, and the repetition would push out entries that matter.
      DebugLog.instance.once(
        'status-cache-write',
        LogLevel.info,
        'Catalogue',
        'Cache des statuts non enregistré : les prochains démarrages resteront '
            'lents',
        error: error,
      );
    }
  }

  Future<LyricsStatus> statusOf(String filePath) async {
    final int mtime;
    try {
      mtime = (await File(filePath).lastModified()).millisecondsSinceEpoch;
    } on FileSystemException {
      // Gone, or unreadable. Report it as having nothing rather than failing
      // the whole catalogue over one file.
      return LyricsStatus.none;
    }

    final cached = _cache[filePath];
    if (cached != null && cached.mtime == mtime) return cached.status;

    // The frame-walking reader, not the whole-tag one: this runs across the
    // entire library at startup, and pulling every track's cover art into
    // memory to look for two frames is what made the app slow to open.
    final lyrics = await Id3Reader.readLyricsFrames(filePath);
    final status = lyrics.synced != null
        ? LyricsStatus.synced
        : lyrics.unsynced != null
        ? LyricsStatus.plain
        : LyricsStatus.none;

    _cache[filePath] = _Entry(mtime, status);
    _dirty = true;
    return status;
  }

  /// Resolves every path, in bounded batches, and returns them keyed by path.
  Future<Map<String, LyricsStatus>> statusOfAll(Iterable<String> paths) async {
    await _restore();

    final result = <String, LyricsStatus>{};
    final all = paths.toList(growable: false);

    for (var i = 0; i < all.length; i += _concurrency) {
      final batch = all.skip(i).take(_concurrency);
      final statuses = await Future.wait(batch.map(statusOf));
      var j = 0;
      for (final path in batch) {
        result[path] = statuses[j++];
      }
    }

    await _persist();
    return result;
  }

  /// Drops one entry, for when the caller knows a file changed.
  ///
  /// The modification time normally catches this on its own; this exists for
  /// the case where a write lands inside the same clock tick as the last read.
  void forget(String filePath) {
    _cache.remove(filePath);
    _dirty = true;
  }
}

class _Entry {
  final int mtime;
  final LyricsStatus status;
  const _Entry(this.mtime, this.status);
}
