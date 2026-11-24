import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';
import 'package:musync/features/library/ui/widgets/song_artwork.dart';

final musicScannerProvider = Provider<MusicScanner>((ref) => MusicScanner());

/// Set when the audio permission is refused, so the library screen can show
/// the "grant access" state instead of an empty list that looks like the phone
/// has no music on it.
final libraryPermissionDeniedProvider = StateProvider<PermissionOutcome?>(
  (ref) => null,
);

/// How the library is ordered. Sorting is state rather than a one-off mutation
/// so it survives a rescan.
enum LibrarySort { title, artist, album, dateAdded, duration }

final librarySortProvider = StateProvider<LibrarySort>(
  (ref) => LibrarySort.title,
);

final songListProvider = AsyncNotifierProvider<SongListNotifier, List<Song>>(
  SongListNotifier.new,
);

/// Files the last library scan left out, with the reason each was skipped.
/// Rebuilds with the song list so it always describes the latest scan. Empty
/// when everything was kept — the common case shows nothing.
final ignoredFilesProvider = Provider<List<IgnoredFile>>((ref) {
  ref.watch(songListProvider);
  return ref.watch(musicScannerProvider).lastIgnored;
});

class SongListNotifier extends AsyncNotifier<List<Song>> {
  /// The last scan, unsorted, and the sort [build] last ran under.
  ///
  /// Changing the sort rebuilds this provider, and the rebuild used to
  /// rescan the whole library — a MediaStore query on Android, a tag read
  /// of every file on iOS — with the list blanked to a spinner meanwhile,
  /// for what is only a reordering of songs already in hand. A rebuild
  /// whose only change is the sort now re-sorts [_lastScan]. Every other
  /// rebuild (first build, invalidate after a permission grant) still
  /// scans: the sort is then unchanged, so it cannot take the shortcut.
  List<Song>? _lastScan;
  LibrarySort? _lastSort;

  /// The scan still running, if any. A sort change that lands while a
  /// rescan is in flight (an AI rename invalidated the list, say) waits for
  /// it instead of re-sorting [_lastScan]: Riverpod drops the superseded
  /// build's result, so the shortcut used to put the pre-rename paths back
  /// on screen — and a tap on one said « Fichier introuvable ».
  Future<List<Song>>? _scanInFlight;

  @override
  Future<List<Song>> build() async {
    // Rebuilds when the sort changes, which keeps the ordering logic in one
    // place instead of mutating an already-emitted list.
    final sort = ref.watch(librarySortProvider);
    final previousSort = _lastSort;
    _lastSort = sort;
    if (previousSort != null && previousSort != sort) {
      final pending = _scanInFlight;
      if (pending != null) return _sorted(await pending, sort);
      final cached = _lastScan;
      if (cached != null) return _sorted(cached, sort);
    }
    return _sorted(await _scan(), sort);
  }

  /// Scans the library (empty without the audio permission) and keeps the
  /// result as [_lastScan], tracked in [_scanInFlight] while it runs.
  Future<List<Song>> _scan() {
    final scan = () async {
      // Scanning without permission returns an empty list on Android, which
      // is indistinguishable from "no music"; the screen needs to tell them
      // apart.
      if (!await PermissionService.hasAudioAccess()) {
        _lastScan = null;
        return const <Song>[];
      }
      final songs = await ref.read(musicScannerProvider).scanAllSongs();
      _lastScan = songs;
      return songs;
    }();
    _scanInFlight = scan;
    void settle() {
      if (identical(_scanInFlight, scan)) _scanInFlight = null;
    }

    scan.then((_) => settle(), onError: (Object _) => settle());
    return scan;
  }

  /// Replaces one song in the emitted list after a tag edit, keeping the
  /// current sort order. Cheaper than a full rescan for a change the app
  /// made itself — the new values are already known.
  void updateSong(Song updated) {
    state.whenData((songs) {
      final index = songs.indexOf(updated);
      if (index < 0) return;
      final copy = List<Song>.from(songs)..[index] = updated;
      state = AsyncValue.data(_sorted(copy, ref.read(librarySortProvider)));
      // Keep the raw scan in step, or the next re-sort would bring the old
      // tags back.
      final raw = _lastScan;
      if (raw != null) {
        final rawIndex = raw.indexOf(updated);
        if (rawIndex >= 0) {
          _lastScan = List<Song>.from(raw)..[rawIndex] = updated;
        }
      }
    });
  }

  Future<void> refresh() async {
    // A rescan can see a changed cover under the same MediaStore
    // id (tag editor, cover change): drop the thumbnail cache
    // so rows re-query instead of serving the old picture.
    ThumbnailCache.instance.clear();
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      // Cache only: the refresh re-queries MediaStore, like the initial
      // scan in [build]. No deep re-read of the files' ID3 tags — a
      // pull-to-refresh fired by accident must stay cheap.
      final songs = await _scan();
      return _sorted(songs, ref.read(librarySortProvider));
    });
  }

  static List<Song> _sorted(List<Song> songs, LibrarySort sort) =>
      sortedSongs(songs, sort);
}

/// [songs] ordered by [sort]. Pure, for the library and its tests.
///
/// Ties fall back to the title, so the new sorts (date, length) still read
/// in a stable order. The newest additions come first, the shortest tracks
/// first; a track without a date goes after every dated one.
List<Song> sortedSongs(List<Song> songs, LibrarySort sort) {
  // Lower-cased once per song, not twice per comparison: a sort makes
  // n·log n comparisons, so on 10 000 tracks that was some 270 000 string
  // copies on the UI isolate for one change of sort or one tag edit.
  final keyed = [
    for (final song in songs)
      (
        song: song,
        title: song.title.toLowerCase(),
        text: switch (sort) {
          LibrarySort.artist => song.artist.toLowerCase(),
          LibrarySort.album => song.album.toLowerCase(),
          _ => '',
        },
      ),
  ];
  int byTitle(({Song song, String title, String text}) a,
          ({Song song, String title, String text}) b) =>
      a.title.compareTo(b.title);
  keyed.sort(switch (sort) {
    LibrarySort.title => byTitle,
    LibrarySort.artist || LibrarySort.album => (a, b) => a.text.compareTo(
      b.text,
    ),
    LibrarySort.dateAdded => (a, b) {
      final byDate = (b.song.dateAdded ?? -1).compareTo(
        a.song.dateAdded ?? -1,
      );
      return byDate != 0 ? byDate : byTitle(a, b);
    },
    LibrarySort.duration => (a, b) {
      final byLength = a.song.duration.compareTo(b.song.duration);
      return byLength != 0 ? byLength : byTitle(a, b);
    },
  });
  return [for (final entry in keyed) entry.song];
}
