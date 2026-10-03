import 'dart:io';
import 'dart:typed_data';

import 'package:on_audio_query/on_audio_query.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/tag_mtime_store.dart';

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
  final TagMtimeStore _mtimeStore;

  MusicScanner({OnAudioQuery? audioQuery, TagMtimeStore? mtimeStore})
    : _audioQuery = audioQuery ?? OnAudioQuery(),
      _mtimeStore = mtimeStore ?? const TagMtimeStore();

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

  /// Re-reads title/artist/album straight from the audio files whose content
  /// changed since the last refresh, bypassing the MediaStore cache.
  ///
  /// MediaStore only picks up an external tag edit (Musicolet) on Android's
  /// own schedule, so a refresh that merely re-queries it keeps showing the
  /// old values. This stats every library file and, for each one whose mtime
  /// moved since the last call (or was never recorded), parses TIT2/TPE1/TALB
  /// directly out of the ID3 tag. Unchanged files cost one stat() each and no
  /// tag parsing; the mtimes persist across launches, so a refresh with
  /// nothing edited re-reads zero tags.
  ///
  /// Only MP3 (ID3) files are re-read — other containers keep their MediaStore
  /// values. A file that can't be read keeps its values too: a refresh must
  /// never blank a title it cannot replace.
  Future<List<Song>> refreshMetadataFromFiles(List<Song> songs) async {
    final mtimes = await _mtimeStore.load();
    var dirty = false;
    final updated = <Song>[];

    for (final song in songs) {
      final path = song.filePath;
      final current = await _mtimeOf(path);
      if (current == null) {
        updated.add(song);
        continue;
      }
      if (mtimes[path] != current) {
        mtimes[path] = current;
        dirty = true;
        if (_isMp3(path)) {
          updated.add(
            _withFileMetadata(song, await Id3Reader.readMetadata(path)),
          );
          continue;
        }
      }
      updated.add(song);
    }

    if (dirty) await _mtimeStore.save(mtimes);
    return updated;
  }

  /// File modification time, or null when the file can't be statted. Never
  /// throws: an unreadable file simply keeps its current metadata.
  static Future<int?> _mtimeOf(String path) async {
    try {
      return (await File(path).stat()).modified.millisecondsSinceEpoch;
    } on FileSystemException {
      return null;
    }
  }

  static bool _isMp3(String path) => path.toLowerCase().endsWith('.mp3');

  /// Applies ID3 metadata onto [song]. A field the tag doesn't carry keeps the
  /// MediaStore value — the file was re-read because its bytes changed, but an
  /// absent frame is not an instruction to blank the display.
  Song _withFileMetadata(Song song, TagMetadata meta) {
    var updated = song;
    final title = meta.title?.trim();
    if (title != null && title.isNotEmpty) {
      updated = updated.copyWith(title: title);
    }
    final artist = meta.artist?.trim();
    if (artist != null && artist.isNotEmpty) {
      updated = updated.copyWith(artist: _orUnknown(artist, unknownArtist));
    }
    final album = meta.album?.trim();
    if (album != null && album.isNotEmpty) {
      updated = updated.copyWith(album: _orUnknown(album, unknownAlbum));
    }
    return updated;
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
