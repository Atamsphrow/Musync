/// The catalogue: the library narrowed by a live search and a lyrics-status tab.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/utils/text_search.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';

final lyricsStatusScannerProvider = Provider<LyricsStatusScanner>(
  (ref) => LyricsStatusScanner(),
);

/// Lyrics status for every track, keyed by file path.
///
/// Rebuilt whenever the library is, and cheap on the second pass: the scanner
/// keeps what it read, and only re-opens files whose modification time moved.
final lyricsStatusProvider = FutureProvider<Map<String, LyricsStatus>>((
  ref,
) async {
  final songs = await ref.watch(songListProvider.future);
  return ref
      .read(lyricsStatusScannerProvider)
      .statusOfAll(songs.map((song) => song.filePath));
});

/// The live filter. Matched against title and artist, case-insensitively.
final librarySearchProvider = StateProvider<String>((ref) => '');

/// Which of the three tabs is showing.
final libraryTabProvider = StateProvider<LyricsStatus>(
  (ref) => LyricsStatus.none,
);

/// The library split into the three tabs, once.
///
/// Deliberately watches neither the tab nor the search box, so switching tabs
/// does not recompute it. That is what made the switch perceptibly slow: the
/// filter below watched the tab, so every tap walked all 1876 tracks again to
/// produce a list that had already been produced. Grouping is the same amount of
/// work as filtering for one tab — done once for all three instead of once per
/// tap.
///
/// Recomputed only when the library or its statuses actually change: a scan, or
/// a write that moves a track from one tab to another.
final songsByStatusProvider =
    Provider<AsyncValue<Map<LyricsStatus, List<Song>>>>((ref) {
      final songsAsync = ref.watch(songListProvider);
      final statusAsync = ref.watch(lyricsStatusProvider);

      if (songsAsync.hasError) {
        return AsyncValue.error(
          songsAsync.error!,
          songsAsync.stackTrace ?? StackTrace.empty,
        );
      }
      if (statusAsync.hasError) {
        return AsyncValue.error(
          statusAsync.error!,
          statusAsync.stackTrace ?? StackTrace.empty,
        );
      }

      final songs = songsAsync.valueOrNull;
      final statuses = statusAsync.valueOrNull;
      if (songs == null || statuses == null) return const AsyncValue.loading();

      final grouped = {for (final s in LyricsStatus.values) s: <Song>[]};
      for (final song in songs) {
        grouped[statuses[song.filePath] ?? LyricsStatus.none]!.add(song);
      }
      return AsyncValue.data(grouped);
    });

/// A folded search key per track, computed once per library rather than per
/// keystroke.
///
/// `foldForSearch` allocates a string. Calling it on the title and the artist of
/// every track, on every character typed, is roughly four thousand throwaway
/// strings per keystroke on this library — which is exactly the kind of cost
/// that shows up as a search box that stutters.
final _searchKeysProvider = Provider<Map<String, String>>((ref) {
  final songs = ref.watch(songListProvider).valueOrNull;
  if (songs == null) return const {};

  // Joined on a newline, not a space, so a query cannot straddle the boundary
  // and match the tail of a title against the head of an artist. A single-line
  // text field cannot produce one, which keeps this exactly equivalent to the
  // two separate `contains` calls it replaces.
  return {
    for (final song in songs)
      song.filePath:
          '${foldForSearch(song.title)}'
          '\n${foldForSearch(song.artist)}',
  };
});

/// How many tracks sit in each tab, for the counts on the tab labels.
/// Null value = statuses still scanning; the UI shows "…" instead of a
/// misleading zero.
final lyricsStatusCountsProvider = Provider<Map<LyricsStatus, int?>>((ref) {
  final grouped = ref.watch(songsByStatusProvider).valueOrNull;
  if (grouped == null) return {for (final s in LyricsStatus.values) s: null};

  return {for (final entry in grouped.entries) entry.key: entry.value.length};
});

/// The library after both filters.
///
/// Shows the song list immediately while the lyrics statuses load in the
/// background: blocking the whole catalogue on a 1500-file scan made the
/// app feel slow to open. While statuses are pending, the tab filter is
/// bypassed (all songs shown) and the tab counts show "…"; once the scan
/// lands, the selected tab's filter applies as before.
final filteredSongsProvider = Provider<AsyncValue<List<Song>>>((ref) {
  final grouped = ref.watch(songsByStatusProvider);
  // Folded once here, not once per song.
  final query = foldForSearch(ref.watch(librarySearchProvider).trim());
  final tab = ref.watch(libraryTabProvider);
  // Watched here rather than inside the branch below, so the dependency does
  // not appear and disappear as the box is typed into and cleared.
  final keys = ref.watch(_searchKeysProvider);
  // Fallback while statuses load: the raw song list, unfiltered by tab.
  final songsAsync = ref.watch(songListProvider);

  List<Song> applyQuery(List<Song> songs) {
    if (query.isEmpty) return songs;
    return [
      for (final song in songs)
        if ((keys[song.filePath] ?? '').contains(query)) song,
    ];
  }

  return grouped.when(
    data: (byStatus) => AsyncValue.data(
      applyQuery(byStatus[tab] ?? const <Song>[]),
    ),
    // Statuses still scanning: show everything now, filter when ready.
    loading: () => songsAsync.whenData(applyQuery),
    error: (e, st) => AsyncValue.error(e, st),
  );
});
