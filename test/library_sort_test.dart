// The library's sorts, including the two added ones (date, length).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';
import 'package:musync/features/library/providers/library_provider.dart';

Song _song(int id, String title, {int? added, int length = 1000}) => Song(
      id: id,
      title: title,
      artist: 'A',
      album: 'B',
      duration: length,
      filePath: '/music/$id.mp3',
      dateAdded: added,
    );

/// A scanner whose scans finish when the test says so.
class _GatedScanner extends MusicScanner {
  final scans = <Completer<List<Song>>>[];

  @override
  Future<List<Song>> scanAllSongs() {
    final scan = Completer<List<Song>>();
    scans.add(scan);
    return scan.future;
  }
}

void main() {
  test('a sort change during a rescan shows the rescan, not the old scan',
      () async {
    final scanner = _GatedScanner();
    final container = ProviderContainer(
      overrides: [musicScannerProvider.overrideWithValue(scanner)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(songListProvider, (_, _) {});
    addTearDown(sub.close);

    await Future<void>.delayed(Duration.zero);
    scanner.scans.single.complete([_song(1, 'old name')]);
    await container.read(songListProvider.future);

    // Files renamed by the app: the list is invalidated, a rescan starts…
    container.invalidate(songListProvider);
    container.read(songListProvider);
    await Future<void>.delayed(Duration.zero);
    expect(scanner.scans, hasLength(2));
    // …and the sort changes before it lands.
    container.read(librarySortProvider.notifier).state = LibrarySort.duration;
    container.read(songListProvider);
    await Future<void>.delayed(Duration.zero);
    scanner.scans[1].complete([_song(1, 'new name')]);

    final shown = await container.read(songListProvider.future);
    expect(shown.single.title, 'new name');
    // The sort change itself did not cost a third scan.
    expect(scanner.scans, hasLength(2));
  });

  final songs = [
    _song(1, 'charlie', added: 100, length: 3000),
    _song(2, 'Alpha', added: 300, length: 1000),
    _song(3, 'bravo', length: 2000),
    _song(4, 'delta', added: 300, length: 1000),
  ];

  test('by title, case-insensitive', () {
    expect(
      sortedSongs(songs, LibrarySort.title).map((s) => s.id),
      [2, 3, 1, 4],
    );
  });

  test('recently added first, undated last, ties by title', () {
    expect(
      sortedSongs(songs, LibrarySort.dateAdded).map((s) => s.id),
      [2, 4, 1, 3],
    );
  });

  test('shortest first, ties by title', () {
    expect(
      sortedSongs(songs, LibrarySort.duration).map((s) => s.id),
      [2, 4, 3, 1],
    );
  });

  test('sorting copies, never reorders the input', () {
    final before = songs.map((s) => s.id).toList();
    sortedSongs(songs, LibrarySort.duration);
    expect(songs.map((s) => s.id), before);
  });
}
