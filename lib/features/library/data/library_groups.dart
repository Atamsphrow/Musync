/// The library seen by artist and by album. Pure functions over the song
/// list, so the views stay simple and the rules are testable.
library;

import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';

/// One artist and their tracks, ordered album by album.
class ArtistGroup {
  final String name;
  final List<Song> songs;

  const ArtistGroup(this.name, this.songs);
}

/// One album: its title, the artist most of its tracks name, its tracks in
/// album order.
class AlbumGroup {
  final String title;
  final String artist;
  final List<Song> songs;

  const AlbumGroup({
    required this.title,
    required this.artist,
    required this.songs,
  });
}

int _byTitle(Song a, Song b) =>
    a.title.toLowerCase().compareTo(b.title.toLowerCase());

/// Album order: the track number when the tag has one, then the title.
int compareAlbumOrder(Song a, Song b) {
  final ta = a.track, tb = b.track;
  if (ta != null && tb != null && ta != tb) return ta.compareTo(tb);
  if (ta != null && tb == null) return -1;
  if (ta == null && tb != null) return 1;
  return _byTitle(a, b);
}

/// Groups compare by name, case-insensitively — with the placeholders
/// (« Artiste inconnu », « Album inconnu ») always last: they are not a
/// name, and sorting them among the « A »s buries real artists.
int _compareNames(String a, String b) {
  final ua = MusicScanner.isUnknown(a), ub = MusicScanner.isUnknown(b);
  if (ua != ub) return ua ? 1 : -1;
  return a.toLowerCase().compareTo(b.toLowerCase());
}

/// The library by artist: names merged case-insensitively (the first
/// spelling met wins), each artist's tracks by album then album order.
List<ArtistGroup> groupByArtist(List<Song> songs) {
  final byKey = <String, List<Song>>{};
  final names = <String, String>{};
  for (final song in songs) {
    final key = song.artist.trim().toLowerCase();
    names.putIfAbsent(key, () => song.artist.trim());
    (byKey[key] ??= <Song>[]).add(song);
  }
  final groups = [
    for (final entry in byKey.entries)
      ArtistGroup(
        names[entry.key]!,
        entry.value
          ..sort((a, b) {
            final byAlbum = a.album.toLowerCase().compareTo(
              b.album.toLowerCase(),
            );
            return byAlbum != 0 ? byAlbum : compareAlbumOrder(a, b);
          }),
      ),
  ];
  groups.sort((a, b) => _compareNames(a.name, b.name));
  return groups;
}

/// The library by album: MediaStore's album id when there is one (two
/// « Greatest Hits » by different artists stay apart), the title and the
/// artist otherwise. Tracks in album order; the album's artist is the one
/// most of its tracks name.
List<AlbumGroup> groupByAlbum(List<Song> songs) {
  final byKey = <String, List<Song>>{};
  for (final song in songs) {
    final id = song.albumId;
    final key = id != null
        ? 'id:$id'
        : 'tag:${song.album.trim().toLowerCase()}|'
              '${song.artist.trim().toLowerCase()}';
    (byKey[key] ??= <Song>[]).add(song);
  }
  final groups = <AlbumGroup>[];
  for (final tracks in byKey.values) {
    tracks.sort(compareAlbumOrder);
    final counts = <String, int>{};
    for (final s in tracks) {
      counts[s.artist] = (counts[s.artist] ?? 0) + 1;
    }
    final artist = counts.entries
        .reduce((a, b) => b.value > a.value ? b : a)
        .key;
    groups.add(
      AlbumGroup(title: tracks.first.album, artist: artist, songs: tracks),
    );
  }
  groups.sort((a, b) {
    final byTitle = _compareNames(a.title, b.title);
    return byTitle != 0 ? byTitle : _compareNames(a.artist, b.artist);
  });
  return groups;
}
