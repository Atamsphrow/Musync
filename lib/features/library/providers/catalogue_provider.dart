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
final lyricsStatusCountsProvider = Provider<Map<LyricsStatus, int>>((ref) {
  final grouped = ref.watch(songsByStatusProvider).valueOrNull;
  final counts = {for (final s in LyricsStatus.values) s: 0};
  if (grouped == null) return counts;

  for (final entry in grouped.entries) {
    counts[entry.key] = entry.value.length;
  }
  return counts;
});

/// The library after both filters.
///
/// Stays loading until the statuses are in, rather than showing an unfiltered
/// list: every track would land under whichever tab happens to be selected,
/// which reads as a catalogue that has mis-sorted the whole library.
final filteredSongsProvider = Provider<AsyncValue<List<Song>>>((ref) {
  final grouped = ref.watch(songsByStatusProvider);
  // Folded once here, not once per song.
  final query = foldForSearch(ref.watch(librarySearchProvider).trim());
  final tab = ref.watch(libraryTabProvider);
  // Watched here rather than inside the branch below, so the dependency does
  // not appear and disappear as the box is typed into and cleared.
  final keys = ref.watch(_searchKeysProvider);

  return grouped.whenData((byStatus) {
    final inTab = byStatus[tab] ?? const <Song>[];

    // The common case, and now free: no search, so the tab's list is already
    // the answer and switching tabs costs a map lookup.
    if (query.isEmpty) return inTab;

    return [
      for (final song in inTab)
        if ((keys[song.filePath] ?? '').contains(query)) song,
    ];
  });
});
