import 'dart:typed_data';

import 'package:on_audio_query/on_audio_query.dart';
import 'package:musync/features/library/data/models/song.dart';

/// Reads the device's music library through MediaStore.
///
/// MediaStore is queried rather than the filesystem walked: it is already
/// indexed, it survives scoped storage, and it is the same catalogue every
/// other music app on the phone sees.
/// A file MediaStore returned but the library left out, and why.
class IgnoredFile {
  final String path;
  final String reason;

  const IgnoredFile({required this.path, required this.reason});
}

class MusicScanner {
  final OnAudioQuery _audioQuery;

  MusicScanner({OnAudioQuery? audioQuery})
    : _audioQuery = audioQuery ?? OnAudioQuery();

  /// Only real music: MediaStore also indexes ringtones, notification sounds
  /// and voice recordings, none of which belong in a library screen.
  static const int _minDurationMs = 20 * 1000;

  /// Files left out by the last [scanAllSongs], with the reason each was
  /// skipped. Surfaced in the UI so a missing track can be explained instead
  /// of silently vanishing.
  List<IgnoredFile> lastIgnored = const [];

  Future<List<Song>> scanAllSongs() async {
    final songs = await _audioQuery.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );

    final ignored = <IgnoredFile>[];
    final kept = <Song>[];
    for (final s in songs) {
      // isMusic is null on files MediaStore hasn't classified; those are
      // kept, since excluding them would hide legitimately untagged tracks.
      if (s.isMusic == false) {
        ignored.add(
          IgnoredFile(path: s.data, reason: 'Non classé comme musique'),
        );
        continue;
      }
      if ((s.duration ?? 0) < _minDurationMs) {
        ignored.add(
          IgnoredFile(path: s.data, reason: 'Trop court (< 20 s)'),
        );
        continue;
      }
      if (s.data.isEmpty) {
        ignored.add(
          IgnoredFile(path: s.displayNameWOExt, reason: 'Chemin illisible'),
        );
        continue;
      }
      kept.add(
        Song(
          id: s.id,
          title: s.title.trim().isEmpty ? s.displayNameWOExt : s.title,
          artist: _orUnknown(s.artist, unknownArtist),
          album: _orUnknown(s.album, unknownAlbum),
          albumId: s.albumId,
          duration: s.duration ?? 0,
          filePath: s.data,
        ),
      );
    }
    lastIgnored = List.unmodifiable(ignored);
    return kept;
  }

  /// What an untagged file is shown as.
  ///
  /// Public because they are *display* strings that must never be used as
  /// search terms: sending "Artiste inconnu" to a lyrics API asks for a French
  /// phrase and can only ever come back empty. Anything building a query from a
  /// tag has to be able to recognise them, which means one definition, not a
  /// literal repeated at each call site.
  static const String unknownArtist = 'Artiste inconnu';
  static const String unknownAlbum = 'Album inconnu';

  /// Whether [value] is a placeholder rather than something a tag said.
  static bool isUnknown(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ||
        trimmed == unknownArtist ||
        trimmed == unknownAlbum ||
        trimmed == '<unknown>';
  }

  static String _orUnknown(String? value, String fallback) {
    // MediaStore stores the literal string '<unknown>' for untagged files.
    if (value == null) return fallback;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == '<unknown>') return fallback;
    return trimmed;
  }

  Future<Uint8List?> getArtwork(int songId) {
    return _audioQuery.queryArtwork(
      songId,
      ArtworkType.AUDIO,
      format: ArtworkFormat.JPEG,
      size: 400,
    );
  }
}
