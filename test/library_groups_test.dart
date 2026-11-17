// Artists and albums: grouping, ordering, and the placeholders kept last.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/library_groups.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';

Song _song(
  int id,
  String title, {
  String artist = 'Artist',
  String album = 'Album',
  int? albumId,
  int? track,
}) =>
    Song(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: 1000,
      filePath: '/music/$id.mp3',
      albumId: albumId,
      track: track,
    );

void main() {
  test('artists merge case-insensitively, unknown last', () {
    final groups = groupByArtist([
      _song(1, 'x', artist: 'zed'),
      _song(2, 'y', artist: MusicScanner.unknownArtist),
      _song(3, 'z', artist: 'Abba'),
      _song(4, 'w', artist: 'ABBA'),
    ]);
    expect(groups.map((g) => g.name), ['Abba', 'zed', MusicScanner.unknownArtist]);
    expect(groups.first.songs.map((s) => s.id).toSet(), {3, 4});
  });

  test("an artist's tracks go album by album, in track order", () {
    final groups = groupByArtist([
      _song(1, 'b', album: 'Second', track: 1),
      _song(2, 'a', album: 'First', track: 2),
      _song(3, 'c', album: 'First', track: 1),
    ]);
    expect(groups.single.songs.map((s) => s.id), [3, 2, 1]);
  });

  test('albums by id keep same-named albums apart', () {
    final groups = groupByAlbum([
      _song(1, 'a', album: 'Greatest Hits', artist: 'Queen', albumId: 10),
      _song(2, 'b', album: 'Greatest Hits', artist: 'ABBA', albumId: 20),
    ]);
    expect(groups.length, 2);
    expect(groups.map((g) => g.artist), ['ABBA', 'Queen']);
  });

  test('album tracks by number, untagged after; artist is the majority', () {
    final group = groupByAlbum([
      _song(1, 'z', albumId: 1, track: 2, artist: 'Main'),
      _song(2, 'a', albumId: 1, artist: 'Guest'),
      _song(3, 'm', albumId: 1, track: 1, artist: 'Main'),
    ]).single;
    expect(group.songs.map((s) => s.id), [3, 1, 2]);
    expect(group.artist, 'Main');
  });
}
