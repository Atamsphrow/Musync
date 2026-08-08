import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';

final musicScannerProvider = Provider<MusicScanner>((ref) => MusicScanner());

/// Set when the audio permission is refused, so the library screen can show
/// the "grant access" state instead of an empty list that looks like the phone
/// has no music on it.
final libraryPermissionDeniedProvider =
    StateProvider<PermissionOutcome?>((ref) => null);

/// How the library is ordered. Sorting is state rather than a one-off mutation
/// so it survives a rescan.
enum LibrarySort { title, artist, album }

final librarySortProvider = StateProvider<LibrarySort>((ref) => LibrarySort.title);

final songListProvider =
    AsyncNotifierProvider<SongListNotifier, List<Song>>(SongListNotifier.new);

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

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      if (!await PermissionService.hasAudioAccess()) return const <Song>[];
      return _sorted(
        await ref.read(musicScannerProvider).scanAllSongs(),
        ref.read(librarySortProvider),
      );
    });
  }

  static List<Song> _sorted(List<Song> songs, LibrarySort sort) {
    final compare = switch (sort) {
      LibrarySort.title => (Song a, Song b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      LibrarySort.artist => (Song a, Song b) =>
          a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
      LibrarySort.album => (Song a, Song b) =>
          a.album.toLowerCase().compareTo(b.album.toLowerCase()),
    };
    return List<Song>.from(songs)..sort(compare);
  }
}
