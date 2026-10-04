import 'package:flutter/foundation.dart';
import 'package:musync/features/library/data/models/song.dart';

/// A user-managed playback queue: a name, a snapshot of songs, and the index
/// of the song that was current when the queue was last active.
///
/// Songs are serialized in full (id, title, artist, album, duration,
/// file path, album id) rather than as bare paths: the queue is a snapshot
/// and must survive a restart even when the library has not been scanned yet.
/// A queue never depends on the library to resolve its own songs.
@immutable
class NamedQueue {
  /// Stable identifier used for persistence and for the default queue.
  final String id;

  final String name;

  final List<Song> songs;

  /// Index of the current song inside [songs]. Clamped defensively: it may
  /// have been persisted while the list was longer.
  final int currentIndex;

  const NamedQueue({
    required this.id,
    required this.name,
    List<Song>? songs,
    this.currentIndex = 0,
  }) : songs = songs ?? const [];

  int get length => songs.length;

  bool get isEmpty => songs.isEmpty;

  /// The song [currentIndex] points at, or null when the queue is empty.
  Song? get currentSong {
    if (songs.isEmpty) return null;
    return songs[currentIndex.clamp(0, songs.length - 1)];
  }

  /// Where playback should resume when this queue is activated.
  int get resumeIndex => songs.isEmpty ? 0 : currentIndex.clamp(0, songs.length - 1);

  NamedQueue copyWith({String? id, String? name, List<Song>? songs, int? currentIndex}) {
    return NamedQueue(
      id: id ?? this.id,
      name: name ?? this.name,
      songs: songs ?? this.songs,
      currentIndex: currentIndex ?? this.currentIndex,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'currentIndex': currentIndex,
        'songs': [for (final s in songs) _songToJson(s)],
      };

  factory NamedQueue.fromJson(Map<String, dynamic> json) {
    final rawSongs = json['songs'];
    return NamedQueue(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      currentIndex: (json['currentIndex'] as num?)?.toInt() ?? 0,
      songs: [
        if (rawSongs is List)
          for (final raw in rawSongs)
            if (raw is Map<String, dynamic>) _songFromJson(raw),
      ],
    );
  }

  /// True when the queue came back from storage with everything it needs:
  /// a non-empty id and name. Corrupt entries are dropped on load instead of
  /// crashing the whole list.
  bool get isValid => id.isNotEmpty && name.isNotEmpty;
}

/// Serialized next to [NamedQueue] on purpose: `Song` itself stays a pure
/// value object with no JSON knowledge, so tag/library refactors never have
/// to think about the queue store format.
Map<String, dynamic> _songToJson(Song song) => {
      'id': song.id,
      'title': song.title,
      'artist': song.artist,
      'album': song.album,
      'duration': song.duration,
      'filePath': song.filePath,
      'albumId': song.albumId,
    };

Song _songFromJson(Map<String, dynamic> json) => Song(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String? ?? '',
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      filePath: json['filePath'] as String? ?? '',
      albumId: (json['albumId'] as num?)?.toInt(),
    );
