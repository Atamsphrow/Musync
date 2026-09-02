/// Cover art for the media notification, taken from the tag itself.
///
/// The obvious address — `content://media/external/audio/albumart/<albumId>` —
/// is dead. It was served by a MediaStore column removed in Android 10, and on
/// a phone running 13 it resolves to nothing. Handing that to `audio_service`
/// asked it to fetch an image that cannot exist, which is a poor foundation for
/// a notification that has to appear every time something plays.
///
/// The bytes are already in the file. Musync has an ID3 reader; it can pull the
/// APIC frame out, drop it in the cache directory, and hand over a `file://`
/// URI that is simply a file on disk.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:path_provider/path_provider.dart';

class ArtworkCache {
  /// Resolved paths, so a track already extracted costs nothing.
  final Map<String, Uri?> _known = <String, Uri?>{};

  Directory? _dir;

  /// Resolves the cache directory, re-creating it when it has gone.
  ///
  /// Remembering it and trusting it was a real bug, and the user's own log caught
  /// it:
  ///
  /// ```
  /// [Pochette] Extraction impossible
  ///   PathNotFoundException: Cannot open file,
  ///   path = '…/cache/artwork/album_6616158705111508652' (errno = 2)
  /// ```
  ///
  /// Android empties an app's cache directory whenever it wants the space — that
  /// is what the directory is *for*. The path was resolved once at startup and
  /// held forever, so after the first clear every write failed and no track ever
  /// got a thumbnail again for the rest of the run. The `exists` check is one
  /// stat per extraction, which is nothing beside reading an APIC frame.
  Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null && await cached.exists()) return cached;

    // Whatever the map remembers now points at files that are gone.
    if (cached != null) _forgetAll();

    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}artwork');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  /// What is already extracted, without touching the disk.
  ///
  /// Used for the rest of the queue: pulling the artwork out of three hundred
  /// tracks to build one notification would be absurd, so they get whatever a
  /// previous play already produced and nothing otherwise.
  Uri? cached(Song song) => _known[_keyFor(song)];

  /// Forgets what the cache directory no longer holds.
  ///
  /// The in-memory map remembers a `file://` URI; Android clearing the directory
  /// leaves it pointing at nothing, and `MediaItem.artUri` would then name a
  /// file that is gone. Called when the directory has had to be re-created.
  void _forgetAll() => _known.clear();

  /// Extracts [song]'s cover, or returns null when it has none.
  ///
  /// Never throws. A track whose tag cannot be read still has to play, and a
  /// notification without a thumbnail is worth far more than no notification.
  Future<Uri?> extract(Song song) async {
    final key = _keyFor(song);
    if (_known.containsKey(key)) return _known[key];

    try {
      final dir = await _directory();
      final file = File('${dir.path}${Platform.pathSeparator}$key');
      if (await file.exists()) return _known[key] = file.uri;

      final picture = await _readPicture(song.filePath);
      if (picture == null) return _known[key] = null;

      await file.writeAsBytes(picture, flush: true);
      return _known[key] = file.uri;
    } catch (error) {
      // Once per session, for the same reason as the palette above: this runs
      // per track, and a thousand identical lines would bury the log.
      DebugLog.instance.once(
        'artwork-extract',
        LogLevel.info,
        'Pochette',
        'Extraction impossible : la notification restera sans vignette',
        error: error,
      );
      return _known[key] = null;
    }
  }

  /// The image bytes of the first APIC frame.
  ///
  /// Walks the frame headers and reads only that one body — the same trick the
  /// lyrics scanner uses, for the same reason: the rest of the tag is of no
  /// interest and the artwork is the expensive part.
  static Future<Uint8List?> _readPicture(String filePath) async {
    final handle = await File(filePath).open();
    try {
      final header = await handle.read(10);
      if (header.length < 10) return null;
      if (header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) {
        return null;
      }

      final major = header[3];
      if (major != 3 && major != 4) return null;
      // Unsynchronised or extended-header tags need the whole-body treatment,
      // and are rare enough not to be worth a second walk here.
      if (header[5] & 0xC0 != 0) return null;

      final declared = Id3Tag.readSynchsafe(header, 6);
      var walked = 0;

      while (walked + 10 <= declared) {
        final frame = await handle.read(10);
        if (frame.length < 10) break;

        final id = String.fromCharCodes(frame, 0, 4);
        if (!Id3Tag.isFrameId(id)) break;

        final size = major == 4
            ? Id3Tag.readSynchsafe(frame, 4)
            : Id3Tag.readBigEndian(frame, 4);
        // Size zero is an empty frame, not the end of the tag. Stopping here
        // was how a stray empty frame in front of APIC cost the cover art.
        if (size < 0 || walked + 10 + size > declared) break;
        walked += 10 + size;

        if (id != 'APIC') {
          await handle.setPosition(await handle.position() + size);
          continue;
        }
        return _imageOf(await handle.read(size));
      }
      return null;
    } on FileSystemException {
      return null;
    } finally {
      await handle.close();
    }
  }

  /// Strips APIC's header off the image.
  ///
  /// Layout: encoding byte, a null-terminated MIME string, one picture-type
  /// byte, then a description in that encoding, then the bytes themselves.
  static Uint8List? _imageOf(Uint8List body) {
    if (body.length < 4) return null;
    final encoding = body[0];

    var i = 1;
    while (i < body.length && body[i] != 0) {
      i++;
    }
    i++; // the MIME terminator
    if (i >= body.length) return null;
    i++; // picture type

    final end = Id3Tag.findTerminator(body, i, encoding);
    if (end < 0) return null;
    final start = end + Id3Encoding.terminatorLength(encoding);
    if (start >= body.length) return null;

    return Uint8List.sublistView(body, start);
  }

  /// One file per album where there is one, per track otherwise: an album's
  /// tracks share a cover, and extracting it a dozen times would be waste.
  static String _keyFor(Song song) =>
      song.albumId != null ? 'album_${song.albumId}' : 'song_${song.id}';
}
