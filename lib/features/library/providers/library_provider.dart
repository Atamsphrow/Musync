import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';

final musicScannerProvider = Provider<MusicScanner>((ref) => MusicScanner());

/// Set when the audio permission is refused, so the library screen can show
/// the "grant access" state instead of an empty list that looks like the phone
/// has no music on it.
final libraryPermissionDeniedProvider = StateProvider<PermissionOutcome?>(
  (ref) => null,
);

/// How the library is ordered. Sorting is state rather than a one-off mutation
/// so it survives a rescan.
enum LibrarySort { title, artist, album }

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
  @override
  Future<List<Song>> build() async {
    // Rebuilds when the sort changes, which keeps the ordering logic in one
    // place instead of mutating an already-emitted list.
    final sort = ref.watch(librarySortProvider);

    // Scanning without permission returns an empty list on Android, which is
    // indistinguishable from "no music"; the screen needs to tell them apart.
    if (!await PermissionService.hasAudioAccess()) return const [];

    final songs = await ref.read(musicScannerProvider).scanAllSongs();
    return _sorted(songs, sort);
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
    });
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      if (!await PermissionService.hasAudioAccess()) return const <Song>[];
      final scanner = ref.read(musicScannerProvider);
      final songs = await scanner.scanAllSongs();
      // Deep rescan, manual refresh only: re-read the ID3 tags of files
      // whose content changed since the last refresh, straight from the
      // files instead of the MediaStore cache. The initial scan in
      // [build] stays MediaStore-only so app launch stays fast.
      final fresh = await scanner.refreshMetadataFromFiles(songs);
      return _sorted(fresh, ref.read(librarySortProvider));
    });
  }

  static List<Song> _sorted(List<Song> songs, LibrarySort sort) {
    final compare = switch (sort) {
      LibrarySort.title => (Song a, Song b) => a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      ),
      LibrarySort.artist =>
        (Song a, Song b) =>
            a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
      LibrarySort.album => (Song a, Song b) => a.album.toLowerCase().compareTo(
        b.album.toLowerCase(),
      ),
    };
    return List<Song>.from(songs)..sort(compare);
  }
}
