// The library's sorts, including the two added ones (date, length).
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/models/song.dart';
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

void main() {
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
