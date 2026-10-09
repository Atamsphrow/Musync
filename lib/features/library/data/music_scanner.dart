import 'dart:io';
import 'dart:typed_data';

import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/features/library/data/excluded_dirs_store.dart';
import 'package:musync/features/library/data/excluded_files_store.dart';
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
  final ExcludedDirsStore _excludedDirsStore;
  final ExcludedFilesStore _excludedFilesStore;

  MusicScanner({
    OnAudioQuery? audioQuery,
    TagMtimeStore? mtimeStore,
    ExcludedDirsStore? excludedDirsStore,
    ExcludedFilesStore? excludedFilesStore,
  }) : _audioQuery = audioQuery ?? OnAudioQuery(),
       _mtimeStore = mtimeStore ?? const TagMtimeStore(),
       _excludedDirsStore = excludedDirsStore ?? const ExcludedDirsStore(),
       _excludedFilesStore = excludedFilesStore ?? const ExcludedFilesStore();

  /// Only real music: MediaStore also indexes ringtones, notification sounds
  /// and voice recordings, none of which belong in a library screen.
  static const int _minDurationMs = 20 * 1000;

  /// Files left out by the last [scanAllSongs], with the reason each was
  /// skipped. Surfaced in the UI so a missing track can be explained instead
  /// of silently vanishing.
  List<IgnoredFile> lastIgnored = const [];

  Future<List<Song>> scanAllSongs() async {
    // iOS : pas de MediaStore. La bibliothèque, c'est le dossier Documents
    // de l'app, rempli depuis l'app Fichiers de l'iPhone (partage de
    // fichiers iTunes activé dans Info.plist).
    if (Platform.isIOS) return _scanDocuments();
    final songs = await _audioQuery.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );

    // Directories the user excluded in Paramètres › Bibliothèque. Read fresh
    // each scan: the scanner is long-lived, and the list changes from the
    // settings screen without the library being rebuilt.
    final excludedDirs = await _excludedDirsStore.load();
    final excludedFiles = await _excludedFilesStore.load();

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
        ignored.add(IgnoredFile(path: s.data, reason: 'Trop court (< 20 s)'));
        continue;
      }
      if (s.data.isEmpty) {
        ignored.add(
          IgnoredFile(path: s.displayNameWOExt, reason: 'Chemin illisible'),
        );
        continue;
      }
      if (ExcludedDirsStore.isExcluded(s.data, excludedDirs)) {
        ignored.add(IgnoredFile(path: s.data, reason: 'Dossier exclu'));
        continue;
      }
      if (ExcludedFilesStore.isExcluded(s.data, excludedFiles)) {
        ignored.add(IgnoredFile(path: s.data, reason: 'Fichier exclu'));
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

  /// Extensions audio reconnues dans le dossier Documents (iOS).
  static const _audioExtensions = {
    '.mp3', '.m4a', '.mp4', '.flac', '.ogg', '.oga', '.opus', '.wav', '.aac',
  };

  /// Id stable d'un morceau iOS, dérivé de son chemin (FNV-1a 32 bits).
  ///
  /// `String.hashCode` n'est pas contractuellement stable d'un lancement à
  /// l'autre ; ce hash-ci l'est, ce qui évite que toute la bibliothèque
  /// change d'identifiant à chaque redémarrage.
  static int stableIdForPath(String path) {
    var hash = 0x811c9dc5;
    for (final unit in path.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  /// Scan iOS : marche le dossier Documents de l'app et construit les
  /// morceaux depuis les fichiers eux-mêmes (tags ID3 pour les MP3, nom de
  /// fichier sinon). Pas de filtre de durée : il n'y a ni sonneries ni
  /// notifications dans Documents, et la durée n'est pas lisible sans
  /// décoder.
  Future<List<Song>> _scanDocuments() async {
    final ignored = <IgnoredFile>[];
    final kept = <Song>[];
    late final Directory docs;
    try {
      docs = await getApplicationDocumentsDirectory();
    } catch (_) {
      lastIgnored = const [];
      return const [];
    }
    if (!await docs.exists()) {
      lastIgnored = const [];
      return const [];
    }
    final excludedDirs = await _excludedDirsStore.load();
    final excludedFiles = await _excludedFilesStore.load();
    await for (final entity in docs.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      final dot = path.lastIndexOf('.');
      final ext = dot < 0 ? '' : path.substring(dot).toLowerCase();
      if (!_audioExtensions.contains(ext)) continue;
      if (ExcludedDirsStore.isExcluded(path, excludedDirs)) {
        ignored.add(IgnoredFile(path: path, reason: 'Dossier exclu'));
        continue;
      }
      if (ExcludedFilesStore.isExcluded(path, excludedFiles)) {
        ignored.add(IgnoredFile(path: path, reason: 'Fichier exclu'));
        continue;
      }
      kept.add(await _songFromFile(path));
    }
    lastIgnored = List.unmodifiable(ignored);
    return kept;
  }

  /// Construit un [Song] depuis un fichier (iOS) : tags ID3 pour les MP3,
  /// nom de fichier nettoyé pour le reste.
  Future<Song> _songFromFile(String path) async {
    var title = _basenameWithoutExtension(path);
    var artist = unknownArtist;
    var album = unknownAlbum;
    if (path.toLowerCase().endsWith('.mp3')) {
      try {
        final meta = await Id3Reader.readMetadata(path);
        final t = meta.title?.trim();
        if (t != null && t.isNotEmpty) title = t;
        final a = meta.artist?.trim();
        if (a != null && a.isNotEmpty && a != '<unknown>') artist = a;
        final al = meta.album?.trim();
        if (al != null && al.isNotEmpty && al != '<unknown>') album = al;
      } catch (_) {
        // Tag illisible : on garde le nom de fichier.
      }
    }
    return Song(
      id: stableIdForPath(path),
      title: title,
      artist: artist,
      album: album,
      duration: 0,
      filePath: path,
    );
  }

  static String _basenameWithoutExtension(String path) {
    final sep = path.lastIndexOf(Platform.pathSeparator);
    final base = sep < 0 ? path : path.substring(sep + 1);
    final dot = base.lastIndexOf('.');
    return (dot < 0 ? base : base.substring(0, dot)).replaceAll('_', ' ');
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
      final stat = await _statOf(path);
      if (stat == null) {
        updated.add(song);
        continue;
      }
      // mtime AND size: some tag editors (Musicolet) preserve the mtime when
      // writing, so mtime alone misses their edits. Size catches those.
      final key = '${stat.mtime}:${stat.size}';
      if (mtimes[path] != key) {
        mtimes[path] = key;
        dirty = true;
        if (_isMp3(path)) {
          try {
            updated.add(
              _withFileMetadata(song, await Id3Reader.readMetadata(path)),
            );
          } catch (_) {
            // The file changed but can't be read (removed mid-scan, corrupt
            // tag, I/O error): keep its previous metadata instead of
            // aborting the whole refresh over one bad file.
            updated.add(song);
          }
          continue;
        }
      }
      updated.add(song);
    }

    if (dirty) await _mtimeStore.save(mtimes);
    return updated;
  }

  /// File stat (mtime + size), or null when the file can't be statted. Never
  /// throws: an unreadable file simply keeps its current metadata.
  static Future<({int mtime, int size})?> _statOf(String path) async {
    try {
      final s = await File(path).stat();
      return (mtime: s.modified.millisecondsSinceEpoch, size: s.size);
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
    // iOS : les morceaux viennent du dossier Documents, pas de la
    // bibliothèque Apple Music — aucun artwork requêtable par id.
    if (Platform.isIOS) return Future.value();
    return _audioQuery.queryArtwork(
      songId,
      ArtworkType.AUDIO,
      format: ArtworkFormat.JPEG,
      size: 400,
    );
  }
}
