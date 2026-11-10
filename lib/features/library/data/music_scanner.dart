import 'dart:io';
import 'dart:typed_data';

import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';
import 'package:musync/core/audio/mp3_gapless.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/m4a_writer.dart';
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
      // A null duration means MediaStore hasn't indexed one, not that the
      // track is 0 s long — rejecting it would hide legitimate tracks, the
      // same reason `isMusic == null` is kept just above.
      if (s.duration != null && s.duration! < _minDurationMs) {
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
      final rawTitle = s.title.trim();
      kept.add(
        Song(
          id: s.id,
          title: rawTitle.isEmpty || rawTitle == '<unknown>'
              ? s.displayNameWOExt
              : s.title,
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

  /// Id stable d'un morceau iOS, dérivé de son chemin (FNV-1a 64 bits,
  /// masqué à 63 bits pour rester positif).
  ///
  /// `String.hashCode` n'est pas contractuellement stable d'un lancement à
  /// l'autre ; ce hash-ci l'est, ce qui évite que toute la bibliothèque
  /// change d'identifiant à chaque redémarrage.
  ///
  /// M121 : l'empreinte était en 32 bits — sur une bibliothèque de quelques
  /// milliers de fichiers, le risque de collision devenait non négligeable,
  /// et `Song ==` ne compare que l'id : deux morceaux distincts devenaient
  /// égaux (file d'attente, déduplication, pochettes). La migration des ids
  /// stockés est dans `migrateStoredSongId` (`named_queue.dart`) : chaque
  /// morceau stocké porte aussi son chemin, dont l'id dérive.
  static int stableIdForPath(String path) {
    var hash = 0xcbf29ce484222325;
    for (final unit in path.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
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
    final paths = <String>[];
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
      paths.add(path);
    }
    // Tag reads are I/O-bound, so they run in bounded batches instead of one
    // file at a time — but bounded: opening the whole library at once would
    // spike file handles and memory for no extra speed.
    const batchSize = 8;
    for (var i = 0; i < paths.length; i += batchSize) {
      final batch = paths.skip(i).take(batchSize).toList();
      kept.addAll(await Future.wait(batch.map(_songFromFile)));
    }
    lastIgnored = List.unmodifiable(ignored);
    return kept;
  }

  /// Durée lue depuis le fichier lui-même.
  ///
  /// Sur iOS il n'y a pas de MediaStore : sans ça chaque morceau s'affichait
  /// « 0:00 ». Lecture pure Dart, sans décoder ni code plateforme : en-tête
  /// Xing pour les MP3, `mvhd` pour les M4A, STREAMINFO pour les FLAC,
  /// fmt/data pour les WAV. Null quand la durée n'est pas lisible sans
  /// décoder (Ogg/Opus, MP3 sans Xing, …) — l'appelant garde alors 0.
  /// Jamais d'exception : un fichier illisible n'a simplement pas de durée.
  static Future<Duration?> probeFileDuration(String path) async {
    final lower = path.toLowerCase();
    try {
      if (lower.endsWith('.mp3')) {
        return (await Mp3GaplessReader.read(path))?.duration;
      }
      if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) {
        return await M4aWriter.readDuration(path);
      }
      if (lower.endsWith('.flac')) return await _flacDuration(path);
      if (lower.endsWith('.wav')) return await _wavDuration(path);
    } catch (_) {
      return null;
    }
    return null;
  }

  /// FLAC : STREAMINFO porte le nombre total d'échantillons et la fréquence
  /// d'échantillonnage (34 octets, premier bloc de métadonnées).
  static Future<Duration?> _flacDuration(String path) async {
    RandomAccessFile? handle;
    try {
      handle = await File(path).open();
      final head = await handle.read(42);
      if (head.length < 42) return null;
      if (head[0] != 0x66 || // 'f'
              head[1] != 0x4C || // 'L'
              head[2] != 0x61 || // 'a'
              head[3] != 0x43) {
        return null; // 'C'
      }
      // Premier bloc : type 0 (STREAMINFO), longueur 34.
      if (head[4] & 0x7F != 0 ||
          head[5] != 0 ||
          head[6] != 0 ||
          head[7] != 34) {
        return null;
      }
      final info = head.sublist(8, 42);
      final sampleRate = (info[10] << 12) | (info[11] << 4) | (info[12] >> 4);
      final totalSamples =
          ((info[13] & 0x0F) << 32) |
          (info[14] << 24) |
          (info[15] << 16) |
          (info[16] << 8) |
          info[17];
      if (sampleRate <= 0 || totalSamples <= 0) return null;
      return Duration(
        microseconds: (totalSamples * 1000000 / sampleRate).round(),
      );
    } catch (_) {
      return null;
    } finally {
      await handle?.close();
    }
  }

  /// WAV : `byteRate` du chunk fmt et taille du chunk data.
  static Future<Duration?> _wavDuration(String path) async {
    RandomAccessFile? handle;
    try {
      handle = await File(path).open();
      final head = await handle.read(4096);
      if (head.length < 44) return null;
      if (head[0] != 0x52 || // 'R'
              head[1] != 0x49 || // 'I'
              head[2] != 0x46 || // 'F'
              head[3] != 0x46 || // 'F'
              head[8] != 0x57 || // 'W'
              head[9] != 0x41 || // 'A'
              head[10] != 0x56 || // 'V'
              head[11] != 0x45) {
        return null; // 'E'
      }
      int byteRate = 0;
      var dataSize = -1;
      var offset = 12;
      int u32le(int at) =>
          head[at] |
          (head[at + 1] << 8) |
          (head[at + 2] << 16) |
          (head[at + 3] << 24);
      while (offset + 8 <= head.length) {
        final id = String.fromCharCodes(head, offset, offset + 4);
        final size = u32le(offset + 4);
        if (id == 'fmt ' && size >= 16 && offset + 8 + 16 <= head.length) {
          byteRate = u32le(offset + 8 + 8);
        } else if (id == 'data') {
          dataSize = size;
        }
        if (byteRate > 0 && dataSize >= 0) break;
        if (size <= 0 || size == 0xFFFFFFFF) break;
        // Les chunks sont alignés sur 2 octets.
        offset += 8 + size + (size % 2);
      }
      if (byteRate <= 0 || dataSize < 0) return null;
      return Duration(
        microseconds: (dataSize * 1000000 / byteRate).round(),
      );
    } catch (_) {
      return null;
    } finally {
      await handle?.close();
    }
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
        if (t != null && t.isNotEmpty && t != '<unknown>') title = t;
        final a = meta.artist?.trim();
        if (a != null && a.isNotEmpty && a != '<unknown>') artist = a;
        final al = meta.album?.trim();
        if (al != null && al.isNotEmpty && al != '<unknown>') album = al;
      } catch (_) {
        // Tag illisible : on garde le nom de fichier.
      }
    }
    // iOS : pas de MediaStore, la durée vient du fichier lui-même (0 si
    // elle n'est pas lisible sans décoder).
    final probed = await probeFileDuration(path);
    return Song(
      id: stableIdForPath(path),
      title: title,
      artist: artist,
      album: album,
      duration: probed?.inMilliseconds ?? 0,
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
    // A removed / renamed track used to keep a dead path in the persistent
    // tag cache forever, making the cache grow on every library turnover.
    final currentPaths = songs.map((song) => song.filePath).toSet();
    final oldSize = mtimes.length;
    mtimes.removeWhere((path, _) => !currentPaths.contains(path));
    if (mtimes.length != oldSize) dirty = true;
    final updated = <Song>[];

    // Lectures de tags I/O-bound, en lots bornés — comme le scan iOS.
    // Les résultats sont réassemblés dans l'ordre d'entrée.
    const batchSize = 8;
    for (var i = 0; i < songs.length; i += batchSize) {
      final batch = songs.skip(i).take(batchSize).toList();
      final results = await Future.wait(
        batch.map((song) => _refreshOne(song, mtimes)),
      );
      for (final result in results) {
        updated.add(result.song);
        if (result.changed) dirty = true;
      }
    }

    if (dirty) await _mtimeStore.save(mtimes);
    return updated;
  }

  /// Relecture d'un seul fichier : stat, puis tag ID3 si le contenu a bougé.
  ///
  /// La clé `mtime:size` n'est enregistrée qu'après une lecture réussie (ou
  /// quand il n'y a rien à lire, hors MP3) : un échec (fichier retiré en
  /// cours de scan, tag corrompu, I/O) est retenté au prochain rafraîchissement
  /// au lieu d'être mémorisé comme fait.
  Future<({Song song, bool changed})> _refreshOne(
    Song song,
    Map<String, String> mtimes,
  ) async {
    final path = song.filePath;
    final stat = await _statOf(path);
    if (stat == null) return (song: song, changed: false);
    // mtime AND size: some tag editors (Musicolet) preserve the mtime when
    // writing, so mtime alone misses their edits. Size catches those.
    final key = '${stat.mtime}:${stat.size}';
    if (mtimes[path] == key) return (song: song, changed: false);
    if (_isMp3(path)) {
      try {
        final updated = _withFileMetadata(
          song,
          await Id3Reader.readMetadata(path),
        );
        mtimes[path] = key;
        return (song: updated, changed: true);
      } catch (_) {
        // The file changed but can't be read (removed mid-scan, corrupt
        // tag, I/O error): keep its previous metadata instead of
        // aborting the whole refresh over one bad file — and don't record
        // the key, so the next refresh retries.
        return (song: song, changed: false);
      }
    }
    mtimes[path] = key;
    return (song: song, changed: true);
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
    if (title != null && title.isNotEmpty && title != '<unknown>') {
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
