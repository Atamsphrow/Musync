import 'package:flutter/foundation.dart';

@immutable
class Song {
  /// MediaStore id. Unique and stable per file, and the key `on_audio_query`
  /// uses for artwork lookups.
  final int id;

  final String title;
  final String artist;
  final String album;

  /// MediaStore album id — needed to build [artworkUri], which is a different
  /// thing from the song's own content URI.
  final int? albumId;

  /// Track length in milliseconds.
  final int duration;

  /// Absolute path on disk. This is what the ID3 reader and writer act on.
  final String filePath;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.filePath,
    this.albumId,
  });

  // There was an `artworkUri` here, building
  // `content://media/external/audio/albumart/<albumId>`. It is gone: that
  // provider was removed in Android 10, so the address resolved to nothing and
  // the media notification was asked to fetch an image that cannot exist.
  // Cover art now comes out of the tag — see ArtworkCache.

  Duration get durationValue => Duration(milliseconds: duration);

  Song copyWith({
    int? id,
    String? title,
    String? artist,
    String? album,
    int? albumId,
    int? duration,
    String? filePath,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumId: albumId ?? this.albumId,
      duration: duration ?? this.duration,
      filePath: filePath ?? this.filePath,
    );
  }

  /// Identity is the MediaStore id alone.
  ///
  /// Without this, `List.indexOf` in the player queue falls back to identity
  /// comparison and returns -1 for a song rebuilt by a fresh scan — which is
  /// how "play this track" used to start the queue from the wrong song.
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Song && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Song($id, "$title" — $artist)';
}
