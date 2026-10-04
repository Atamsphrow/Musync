import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:musync/core/id3/audio_container.dart';
import 'package:musync/core/id3/tag_metadata.dart';

/// Raised when M4A lyrics can't be written. Same contract as
/// [Id3WriteException]: the message is meant for the user, the cause is for
/// the log.
class M4aWriteException implements Exception {
  final String message;
  final Object? cause;

  const M4aWriteException(this.message, [this.cause]);

  @override
  String toString() => 'M4aWriteException: $message';
}

/// Writes lyrics into an M4A/MP4 file's `©lyr` atom.
///
/// The lyrics live at `moov > udta > meta > ilst > ©lyr`, as UTF-8 text in a
/// `data` child atom — the iTunes convention. Synchronised lyrics are stored
/// as LRC text (`[mm:ss.xx]` prefixes), exactly what Musync puts in the USLT
/// frame of an MP3, so Musicolet and other players see the timings.
///
/// # Safety
///
/// MP4 atoms carry absolute file offsets (notably the `stco`/`co64` chunk
/// tables), so a naive size change corrupts playback. This writer:
///
/// 1. Never touches the original: the new file is built in memory, written to
///    a sibling `.musync.tmp` file, **re-parsed and verified** (atom
///    structure sane, `©lyr` readable and matching what was written), and
///    only then atomically renamed over the original.
/// 2. Fixes up every `stco`/`co64` entry when `moov` changes size in front of
///    `mdat`.
/// 3. On any failure at any step, the temp file is deleted and the original
///    is byte-for-byte untouched.
class M4aWriter {
  const M4aWriter._();

  /// Atom type for `©lyr`: 0xA9 'l' 'y' 'r'.
  static const List<int> _lyrType = [0xA9, 0x6C, 0x79, 0x72];

  /// Metadata atom types (iTunes convention).
  static const List<int> _namType = [0xA9, 0x6E, 0x61, 0x6D]; // ©nam title
  static const List<int> _artType = [0xA9, 0x41, 0x52, 0x54]; // ©ART artist
  static const List<int> _albType = [0xA9, 0x61, 0x6C, 0x62]; // ©alb album
  static const List<int> _aartType = [0x61, 0x41, 0x52, 0x54]; // aART album artist
  static const List<int> _genType = [0xA9, 0x67, 0x65, 0x6E]; // ©gen genre
  static const List<int> _dayType = [0xA9, 0x64, 0x61, 0x79]; // ©day year
  static const List<int> _cmtType = [0xA9, 0x63, 0x6D, 0x74]; // ©cmt comment
  static const List<int> _wrtType = [0xA9, 0x77, 0x72, 0x74]; // ©wrt composer
  static const List<int> _trknType = [0x74, 0x72, 0x6B, 0x6E]; // trkn track
  static const List<int> _diskType = [0x64, 0x69, 0x73, 0x6B]; // disk disc
  static const List<int> _covrType = [0x63, 0x6F, 0x76, 0x72]; // covr artwork

  /// Replaces the `©lyr` lyrics of [filePath] with [lrcText].
  ///
  /// Passing null (or empty) removes the lyrics atom if present.
  /// Throws [M4aWriteException] if the file can't be written — the original
  /// is left intact in every failure case.
  static Future<void> writeLrc(String filePath, String? lrcText) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw M4aWriteException('Fichier introuvable : $filePath');
    }

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException catch (e) {
      throw M4aWriteException(
        'Lecture impossible : ${e.osError?.message ?? e.message}',
        e,
      );
    }

    if (AudioContainerReader.detect(bytes) != AudioContainer.mp4) {
      throw M4aWriteException('Pas un fichier MP4 / M4A.');
    }

    final text = (lrcText == null || lrcText.isEmpty) ? null : lrcText;

    final Uint8List newBytes;
    try {
      newBytes = _buildFileWithLyrics(bytes, text);
    } catch (e) {
      throw M4aWriteException(
        'Structure MP4 illisible ou non prise en charge : impossible d\'y '
        'écrire sans risque.',
        e,
      );
    }

    // Atomic swap: temp file, verify, rename. The original is never opened
    // for writing.
    final temp = File('$filePath.musync.tmp');
    try {
      await temp.writeAsBytes(newBytes, flush: true);
      final written = await temp.readAsBytes();
      _verifyTempFile(written, text);
      await temp.rename(file.path);
    } catch (e) {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // Best effort — the original is untouched either way.
        }
      }
      if (e is M4aWriteException) rethrow;
      throw M4aWriteException(_describeWriteFailure(e), e);
    }
  }

  /// Reads the LRC lyrics text from [filePath]'s `©lyr` atom.
  ///
  /// Returns null if the file has no `©lyr` or it can't be read. The text is
  /// LRC (`[mm:ss.xx]` prefixes) when the lyrics are synchronised, plain
  /// text otherwise — the same convention as the USLT frame of an MP3.
  static Future<String?> readLrc(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      return null;
    }
    if (AudioContainerReader.detect(bytes) != AudioContainer.mp4) return null;
    try {
      final topLevel = _parseChildren(bytes, 0, bytes.length, 0);
      final moov = _findByType(topLevel, 'moov');
      if (moov == null) return null;
      final moovPayload = bytes.sublist(
        moov.offset + moov.headerSize,
        moov.offset + moov.size,
      );
      final ilst = _childPayload(moovPayload, ['udta', 'meta', 'ilst']);
      if (ilst == null) return null;
      final children = _parseChildren(ilst, 0, ilst.length, 0);
      final lyr = _findByTypeBytes(children, _lyrType);
      if (lyr == null) return null;
      return _readLyrText(ilst, lyr);
    } catch (_) {
      return null;
    }
  }

  // ── File assembly ──

  /// Reads the tag-editor metadata (`©nam`, `©ART`, `©alb`, …, `trkn`,
  /// `disk`, `covr`) from [filePath].
  ///
  /// A field the file doesn't carry is null. Never throws: an unreadable
  /// file reads as "nothing to pre-fill".
  static Future<TrackMetadata> readMetadata(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return emptyTrackMetadata;
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      return emptyTrackMetadata;
    }
    return metadataFromBytes(bytes);
  }

  /// Same as [readMetadata], against bytes already in memory.
  static TrackMetadata metadataFromBytes(Uint8List bytes) {
    if (AudioContainerReader.detect(bytes) != AudioContainer.mp4) {
      return emptyTrackMetadata;
    }
    try {
      final topLevel = _parseChildren(bytes, 0, bytes.length, 0);
      final moov = _findByType(topLevel, 'moov');
      if (moov == null) return emptyTrackMetadata;
      final moovPayload = bytes.sublist(
        moov.offset + moov.headerSize,
        moov.offset + moov.size,
      );
      final ilst = _childPayload(moovPayload, ['udta', 'meta', 'ilst']);
      if (ilst == null) return emptyTrackMetadata;
      final children = _parseChildren(ilst, 0, ilst.length, 0);

      String? text(List<int> type) {
        final atom = _findByTypeBytes(children, type);
        if (atom == null) return null;
        final value = _readTextData(ilst, atom)?.trim();
        return (value == null || value.isEmpty) ? null : value;
      }

      (int?, int?) pair(List<int> type) {
        final atom = _findByTypeBytes(children, type);
        if (atom == null) return (null, null);
        return _readNumberPair(ilst, atom);
      }

      final track = pair(_trknType);
      final disc = pair(_diskType);
      Uint8List? artwork;
      final covr = _findByTypeBytes(children, _covrType);
      if (covr != null) artwork = _readCovrData(ilst, covr);

      return (
        title: text(_namType),
        artist: text(_artType),
        album: text(_albType),
        albumArtist: text(_aartType),
        genre: text(_genType),
        year: text(_dayType),
        trackNumber: track.$1,
        trackTotal: track.$2,
        discNumber: disc.$1,
        discTotal: disc.$2,
        composer: text(_wrtType),
        comment: text(_cmtType),
        artwork: artwork,
      );
    } catch (_) {
      return emptyTrackMetadata;
    }
  }

  /// Reads the UTF-8 text out of a text atom's `data` child.
  static String? _readTextData(Uint8List ilst, _AtomHeader atom) {
    final payload = ilst.sublist(
      atom.offset + atom.headerSize,
      atom.offset + atom.size,
    );
    final children = _parseChildren(payload, 0, payload.length, 0);
    final data = _findByType(children, 'data');
    if (data == null) return null;
    // type(4) + locale(4), then text.
    final start = data.offset + data.headerSize + 8;
    final end = data.offset + data.size;
    if (start > end) return null;
    try {
      return utf8.decode(payload.sublist(start, end));
    } catch (_) {
      return null;
    }
  }

  /// Reads a `trkn`/`disk` number pair: after type/locale, 8 bytes of
  /// reserved(2), number(2), total(2), reserved(2). A zero part reads as
  /// absent, matching what the writer emits for a dropped part.
  static (int?, int?) _readNumberPair(Uint8List ilst, _AtomHeader atom) {
    final payload = ilst.sublist(
      atom.offset + atom.headerSize,
      atom.offset + atom.size,
    );
    final children = _parseChildren(payload, 0, payload.length, 0);
    final data = _findByType(children, 'data');
    if (data == null) return (null, null);
    final start = data.offset + data.headerSize + 8;
    final end = data.offset + data.size;
    if (end - start < 8) return (null, null);
    final number = (payload[start + 2] << 8) | payload[start + 3];
    final total = (payload[start + 4] << 8) | payload[start + 5];
    return (number == 0 ? null : number, total == 0 ? null : total);
  }

  /// Reads the image bytes out of a `covr` atom's `data` child.
  static Uint8List? _readCovrData(Uint8List ilst, _AtomHeader atom) {
    final payload = ilst.sublist(
      atom.offset + atom.headerSize,
      atom.offset + atom.size,
    );
    final children = _parseChildren(payload, 0, payload.length, 0);
    final data = _findByType(children, 'data');
    if (data == null) return null;
    final start = data.offset + data.headerSize + 8;
    final end = data.offset + data.size;
    if (start >= end) return null;
    return Uint8List.sublistView(payload, start, end);
  }

  /// Replaces the tag-editor metadata of [filePath].
  ///
  /// Follows [TrackMetadata]'s contract: a null field is left untouched, an
  /// empty string removes the atom, a negative track/disc number drops that
  /// part of the pair. Every other atom is carried across untouched.
  ///
  /// Same safety as [writeLrc]: the new file is built in memory, written to a
  /// sibling temp file, re-parsed and verified field by field, and only then
  /// atomically renamed over the original. Throws [M4aWriteException] on any
  /// failure — the original is left intact in every case.
  static Future<void> writeMetadata(
    String filePath,
    TrackMetadata metadata,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw M4aWriteException('Fichier introuvable : $filePath');
    }

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException catch (e) {
      throw M4aWriteException(
        'Lecture impossible : ${e.osError?.message ?? e.message}',
        e,
      );
    }

    if (AudioContainerReader.detect(bytes) != AudioContainer.mp4) {
      throw M4aWriteException('Pas un fichier MP4 / M4A.');
    }

    final existing = metadataFromBytes(bytes);

    final changes = <_AtomChange>[];
    void setText(List<int> type, String? value) {
      if (value == null) return;
      changes.add(
        _AtomChange(type, value.isEmpty ? null : _buildTextAtom(type, value)),
      );
    }

    setText(_namType, metadata.title);
    setText(_artType, metadata.artist);
    setText(_albType, metadata.album);
    setText(_aartType, metadata.albumArtist);
    setText(_genType, metadata.genre);
    setText(_dayType, metadata.year);
    setText(_cmtType, metadata.comment);
    setText(_wrtType, metadata.composer);
    _setNumberPair(
      changes,
      _trknType,
      metadata.trackNumber,
      metadata.trackTotal,
      existing.trackNumber,
      existing.trackTotal,
    );
    _setNumberPair(
      changes,
      _diskType,
      metadata.discNumber,
      metadata.discTotal,
      existing.discNumber,
      existing.discTotal,
    );

    final artwork = metadata.artwork;
    if (artwork != null) {
      changes.add(
        _AtomChange(
          _covrType,
          artwork.isEmpty ? null : _buildCovrAtom(artwork),
        ),
      );
    }

    final Uint8List newBytes;
    try {
      newBytes = _buildFileWithIlst(bytes, (ilst) {
        var payload = ilst;
        for (final change in changes) {
          payload = _rebuildWithChild(payload, change.type, change.atom, 0);
        }
        return payload;
      });
    } catch (e) {
      throw M4aWriteException(
        'Structure MP4 illisible ou non prise en charge : impossible d\'y '
        'écrire sans risque.',
        e,
      );
    }

    // Atomic swap: temp file, verify, rename. The original is never opened
    // for writing.
    final temp = File('$filePath.musync.tmp');
    try {
      await temp.writeAsBytes(newBytes, flush: true);
      final written = await temp.readAsBytes();
      _verifyMetadata(written, metadata, existing);
      await temp.rename(file.path);
    } catch (e) {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // Best effort — the original is untouched either way.
        }
      }
      if (e is M4aWriteException) rethrow;
      throw M4aWriteException(_describeWriteFailure(e), e);
    }
  }

  /// Stages a `trkn`/`disk` change: both null means "leave alone". Otherwise
  /// the part the caller didn't set falls back to the existing value, a
  /// negative part drops that part, and when neither part survives the atom
  /// is removed.
  static void _setNumberPair(
    List<_AtomChange> changes,
    List<int> type,
    int? number,
    int? total,
    int? existingNumber,
    int? existingTotal,
  ) {
    if (number == null && total == null) return;
    final n = number == null
        ? existingNumber
        : (number < 0 ? null : number);
    final t = total == null ? existingTotal : (total < 0 ? null : total);
    if (n == null && t == null) {
      changes.add(_AtomChange(type, null));
    } else {
      changes.add(_AtomChange(type, _buildNumberAtom(type, n ?? 0, t ?? 0)));
    }
  }

  /// Re-parses [bytes] (the temp file) and throws unless every field
  /// [metadata] set or removed reads back as expected. Fields it left
  /// untouched are not checked — they were verified by not being rewritten.
  static void _verifyMetadata(
    Uint8List bytes,
    TrackMetadata metadata,
    TrackMetadata existing,
  ) {
    if (AudioContainerReader.detect(bytes) != AudioContainer.mp4) {
      throw const FormatException('temp file is not MP4');
    }
    final read = metadataFromBytes(bytes);

    void checkText(String? value, String? actual, String name) {
      if (value == null) return;
      final expected = value.isEmpty ? null : value;
      if (expected != actual) {
        throw FormatException('temp file $name mismatch');
      }
    }

    checkText(metadata.title, read.title, '©nam');
    checkText(metadata.artist, read.artist, '©ART');
    checkText(metadata.album, read.album, '©alb');
    checkText(metadata.albumArtist, read.albumArtist, 'aART');
    checkText(metadata.genre, read.genre, '©gen');
    checkText(metadata.year, read.year, '©day');
    checkText(metadata.comment, read.comment, '©cmt');
    checkText(metadata.composer, read.composer, '©wrt');

    void checkPair(
      int? number,
      int? total,
      int? existingNumber,
      int? existingTotal,
      int? readNumber,
      int? readTotal,
      String name,
    ) {
      if (number == null && total == null) return;
      final expectedNumber = number == null
          ? existingNumber
          : (number < 0 ? null : number);
      final expectedTotal = total == null
          ? existingTotal
          : (total < 0 ? null : total);
      if (expectedNumber != readNumber || expectedTotal != readTotal) {
        throw FormatException('temp file $name mismatch');
      }
    }

    checkPair(
      metadata.trackNumber,
      metadata.trackTotal,
      existing.trackNumber,
      existing.trackTotal,
      read.trackNumber,
      read.trackTotal,
      'trkn',
    );
    checkPair(
      metadata.discNumber,
      metadata.discTotal,
      existing.discNumber,
      existing.discTotal,
      read.discNumber,
      read.discTotal,
      'disk',
    );

    final artwork = metadata.artwork;
    if (artwork != null) {
      final actual = read.artwork;
      final matches = artwork.isEmpty
          ? actual == null
          : actual != null && _bytesEqual(artwork, actual);
      if (!matches) throw const FormatException('temp file covr mismatch');
    }
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ── File assembly ──

  /// Returns the full new file bytes with the `©lyr` atom replaced/added (or
  /// removed when [text] is null).
  static Uint8List _buildFileWithLyrics(Uint8List bytes, String? text) {
    final newLyr = text == null ? null : _buildLyrAtom(text);
    return _buildFileWithIlst(
      bytes,
      (ilst) => _rebuildWithChild(ilst, _lyrType, newLyr, 0),
    );
  }

  /// Rebuilds the file with [updateIlst] applied to the ilst payload,
  /// creating the `udta > meta > ilst` chain when it is missing.
  ///
  /// The moov atom is rebuilt around the new payload, `stco`/`co64` entries
  /// are fixed up when moov moved in front of `mdat`, and the file is
  /// reassembled around it. Throws [FormatException] when the structure
  /// can't be navigated safely.
  static Uint8List _buildFileWithIlst(
    Uint8List bytes,
    Uint8List Function(Uint8List ilstPayload) updateIlst,
  ) {
    final topLevel = _parseChildren(bytes, 0, bytes.length, 0);
    final moov = _findByType(topLevel, 'moov');
    if (moov == null) {
      throw const FormatException('no moov atom');
    }

    // Rebuild moov with the new ilst.
    final moovPayload = bytes.sublist(
      moov.offset + moov.headerSize,
      moov.offset + moov.size,
    );
    final newMoovPayload = _rebuildMoovWithIlst(moovPayload, updateIlst);
    final newMoov = _makeAtom('moov', newMoovPayload);
    final delta = newMoov.length - moov.size;

    // Fix chunk offsets when moov grew/shrank in front of mdat.
    final Uint8List fixedMoov;
    if (delta != 0 && _moovIsBeforeMdat(topLevel, moov)) {
      fixedMoov = _shiftChunkOffsets(newMoov, delta);
    } else {
      fixedMoov = newMoov;
    }

    // Reassemble: everything before moov + new moov + everything after.
    final out = BytesBuilder(copy: false)
      ..add(bytes.sublist(0, moov.offset))
      ..add(fixedMoov)
      ..add(bytes.sublist(moov.offset + moov.size));
    return out.toBytes();
  }

  /// Rebuilds the moov payload with [updateIlst] applied to the
  /// `udta > meta > ilst` chain, creating any missing parent atoms.
  ///
  /// When the update leaves the ilst empty and the chain had to be created
  /// for it, the moov payload comes back unchanged: a removal on a missing
  /// chain is a no-op, not an empty shell of new atoms. Empty parent atoms
  /// left behind by a removal on an existing chain are valid MP4 and
  /// harmless; pruning them would add risk for no benefit.
  static Uint8List _rebuildMoovWithIlst(
    Uint8List moovPayload,
    Uint8List Function(Uint8List ilstPayload) updateIlst,
  ) {
    // Walk down, creating missing parents on the way when adding.
    final udtaRef = _childRef(moovPayload, 'udta', 0);
    if (udtaRef == null) {
      final newIlstPayload = updateIlst(Uint8List(0));
      if (newIlstPayload.isEmpty) return moovPayload; // nothing to remove
      final ilst = _makeAtom('ilst', newIlstPayload);
      final meta = _makeAtom('meta', _buildMetaPayload(ilst));
      final udta = _makeAtom('udta', meta);
      return _rebuildWithChild(moovPayload, _typeBytes('udta'), udta, 0);
    }

    final metaRef = _childRef(udtaRef.payload, 'meta', 0);
    if (metaRef == null) {
      final newIlstPayload = updateIlst(Uint8List(0));
      if (newIlstPayload.isEmpty) return moovPayload;
      final ilst = _makeAtom('ilst', newIlstPayload);
      final meta = _makeAtom('meta', _buildMetaPayload(ilst));
      final newUdtaPayload =
          _rebuildWithChild(udtaRef.payload, _typeBytes('meta'), meta, 0);
      return _rebuildWithChild(
          moovPayload, _typeBytes('udta'), _makeAtom('udta', newUdtaPayload), 0);
    }

    // meta's children start after 4 version/flags bytes.
    final ilstRef = _childRef(metaRef.payload, 'ilst', 4);
    if (ilstRef == null) {
      final newIlstPayload = updateIlst(Uint8List(0));
      if (newIlstPayload.isEmpty) return moovPayload;
      final ilst = _makeAtom('ilst', newIlstPayload);
      final newMetaPayload =
          _rebuildWithChild(metaRef.payload, _typeBytes('ilst'), ilst, 4);
      final newUdtaPayload = _rebuildWithChild(udtaRef.payload,
          _typeBytes('meta'), _makeAtom('meta', newMetaPayload), 0);
      return _rebuildWithChild(
          moovPayload, _typeBytes('udta'), _makeAtom('udta', newUdtaPayload), 0);
    }

    final newIlstPayload = updateIlst(ilstRef.payload);
    final newIlst = _makeAtom('ilst', newIlstPayload);
    final newMetaPayload =
        _rebuildWithChild(metaRef.payload, _typeBytes('ilst'), newIlst, 4);
    final newUdtaPayload = _rebuildWithChild(udtaRef.payload,
        _typeBytes('meta'), _makeAtom('meta', newMetaPayload), 0);
    return _rebuildWithChild(
        moovPayload, _typeBytes('udta'), _makeAtom('udta', newUdtaPayload), 0);
  }

  /// Builds a `meta` payload with the `hdlr` the iTunes spec requires.
  ///
  /// A `meta` without `hdlr` (handler `mdir`) is technically parseable, but
  /// some players — iTunes included — ignore an `ilst` they can't attribute
  /// to a handler. When we create `meta` from scratch, we do it properly.
  static Uint8List _buildMetaPayload(Uint8List ilst) {
    final hdlrPayload = BytesBuilder(copy: false)
      ..add(Uint8List.fromList([0, 0, 0, 0])) // version + flags
      ..add(Uint8List.fromList([0, 0, 0, 0])) // pre_defined
      ..add(_typeBytes('mdir')) // handler_type: metadata
      ..add(Uint8List.fromList(List.filled(12, 0))) // reserved
      ..add(Uint8List.fromList([0])); // empty name, null-terminated
    final hdlr = _makeAtom('hdlr', hdlrPayload.toBytes());
    final out = BytesBuilder(copy: false)
      ..add(Uint8List.fromList([0, 0, 0, 0])) // meta version/flags
      ..add(hdlr)
      ..add(ilst);
    return out.toBytes();
  }

  /// Returns the payload and range of a direct child, or null if absent.
  static _ChildRef? _childRef(Uint8List payload, String type, int childrenStart) =>
      _childPayloadAndRange(payload, type, childrenStart);

  // ── Atom construction ──

  /// Builds a complete `©lyr` atom with a `data` child holding UTF-8 [text].
  static Uint8List _buildLyrAtom(String text) {
    final textBytes = utf8.encode(text);
    // data atom: size + 'data' + type(1=UTF-8) + locale(0) + text.
    final data = BytesBuilder(copy: false)
      ..add(_u32(16 + textBytes.length))
      ..add(_typeBytes('data'))
      ..add(_u32(1))
      ..add(_u32(0))
      ..add(textBytes);
    return _makeAtomBytes(_lyrType, data.toBytes());
  }

  /// size(4) + type(4) + payload.
  static Uint8List _makeAtom(String type, Uint8List payload) =>
      _makeAtomBytes(_typeBytes(type), payload);

  /// Builds a text metadata atom (`©nam`, `©ART`, …): a `data` child holding
  /// UTF-8 text, the iTunes convention.
  static Uint8List _buildTextAtom(List<int> type, String text) {
    final textBytes = utf8.encode(text);
    final data = BytesBuilder(copy: false)
      ..add(_u32(16 + textBytes.length))
      ..add(_typeBytes('data'))
      ..add(_u32(1)) // UTF-8
      ..add(_u32(0)) // locale
      ..add(textBytes);
    return _makeAtomBytes(type, data.toBytes());
  }

  /// Builds a `trkn`/`disk` atom: a `data` child with 8 binary bytes —
  /// reserved(2), number(2), total(2), reserved(2).
  static Uint8List _buildNumberAtom(List<int> type, int number, int total) {
    final payload = Uint8List(8);
    payload[2] = (number >> 8) & 0xFF;
    payload[3] = number & 0xFF;
    payload[4] = (total >> 8) & 0xFF;
    payload[5] = total & 0xFF;
    final data = BytesBuilder(copy: false)
      ..add(_u32(16 + payload.length))
      ..add(_typeBytes('data'))
      ..add(_u32(0)) // binary
      ..add(_u32(0)) // locale
      ..add(payload);
    return _makeAtomBytes(type, data.toBytes());
  }

  /// Builds a `covr` atom: a `data` child holding the image bytes, typed
  /// JPEG (13) or PNG (14) from the magic bytes.
  static Uint8List _buildCovrAtom(Uint8List image) {
    final kind =
        (image.length >= 4 && image[0] == 0x89 && image[1] == 0x50) ? 14 : 13;
    final data = BytesBuilder(copy: false)
      ..add(_u32(16 + image.length))
      ..add(_typeBytes('data'))
      ..add(_u32(kind))
      ..add(_u32(0)) // locale
      ..add(image);
    return _makeAtomBytes(_covrType, data.toBytes());
  }

  static Uint8List _makeAtomBytes(List<int> type, Uint8List payload) {
    final out = BytesBuilder(copy: false)
      ..add(_u32(8 + payload.length))
      ..add(type)
      ..add(payload);
    return out.toBytes();
  }

  // ── Atom parsing ──

  /// A parsed atom header.
  static _AtomHeader? _readHeader(Uint8List bytes, int offset) {
    if (offset + 8 > bytes.length) return null;
    var size = _readU32(bytes, offset);
    var headerSize = 8;
    if (size == 1) {
      // 64-bit largesize.
      if (offset + 16 > bytes.length) return null;
      size = _readU64(bytes, offset + 8);
      headerSize = 16;
    } else if (size == 0) {
      // Extends to end of file.
      size = bytes.length - offset;
    }
    if (size < headerSize || offset + size > bytes.length) return null;
    return _AtomHeader(
      offset: offset,
      size: size,
      headerSize: headerSize,
      type: bytes.sublist(offset + 4, offset + 8),
    );
  }

  /// Parses direct children of [payload] (a slice starting at [base]).
  /// [childrenStart] skips version/flags (4 for `meta`).
  static List<_AtomHeader> _parseChildren(
    Uint8List bytes,
    int base,
    int end,
    int childrenStart,
  ) {
    final atoms = <_AtomHeader>[];
    var offset = base + childrenStart;
    while (offset + 8 <= end) {
      final header = _readHeader(bytes, offset);
      if (header == null) break;
      if (!_looksLikeType(header.type)) {
        // Custom atom with a non-ASCII type: skip it by its (sane) size
        // instead of stopping, so a later udta/meta/ilst isn't missed and
        // duplicated. If the size is insane, we've hit leaf data — stop.
        if (header.size >= 8 && offset + header.size <= end) {
          offset += header.size;
          continue;
        }
        break;
      }
      atoms.add(header);
      offset += header.size;
    }
    return atoms;
  }

  static bool _looksLikeType(List<int> type) {
    // Atom types are 4 printable ASCII bytes, or 0xA9 + 3 ASCII (©xyz).
    var i = 0;
    if (type[0] == 0xA9) i = 1;
    for (; i < 4; i++) {
      final c = type[i];
      if (c < 0x20 || c > 0x7E) return false;
    }
    return true;
  }

  static _AtomHeader? _findByType(List<_AtomHeader> atoms, String type) {
    final want = _typeBytes(type);
    for (final a in atoms) {
      if (_typeEquals(a.type, want)) return a;
    }
    return null;
  }

  static _AtomHeader? _findByTypeBytes(
      List<_AtomHeader> atoms, List<int> want) {
    for (final a in atoms) {
      if (_typeEquals(a.type, want)) return a;
    }
    return null;
  }

  /// Navigates [path] (e.g. ['udta','meta','ilst']) from [payload] and returns
  /// the leaf's payload, or null if any step is missing.
  static Uint8List? _childPayload(Uint8List payload, List<String> path) {
    var current = payload;
    var childrenStart = 0;
    for (final step in path) {
      final children = _parseChildren(current, 0, current.length, childrenStart);
      final found = _findByType(children, step);
      if (found == null) return null;
      final start = found.offset + found.headerSize;
      current = current.sublist(start, found.offset + found.size);
      childrenStart = step == 'meta' ? 4 : 0;
    }
    return current;
  }

  static _ChildRef? _childPayloadAndRange(
      Uint8List payload, String type, int childrenStart) {
    final children = _parseChildren(payload, 0, payload.length, childrenStart);
    final found = _findByType(children, type);
    if (found == null) return null;
    final start = found.offset + found.headerSize;
    return _ChildRef(
      payload: payload.sublist(start, found.offset + found.size),
      offset: found.offset,
      size: found.size,
    );
  }

  /// Rebuilds [payload], replacing the direct child [childType] with
  /// [newChild] (appended if absent, removed if null).
  static Uint8List _rebuildWithChild(
    Uint8List payload,
    List<int> childType,
    Uint8List? newChild,
    int childrenStart,
  ) {
    final children = _parseChildren(payload, 0, payload.length, childrenStart);
    final existing = _findByTypeBytes(children, childType);

    final out = BytesBuilder(copy: false);
    // Bytes before the children start (e.g. meta's version/flags).
    out.add(payload.sublist(0, childrenStart));

    if (existing == null) {
      // Append: existing children + new child.
      out.add(payload.sublist(childrenStart));
      if (newChild != null) out.add(newChild);
    } else {
      out.add(payload.sublist(childrenStart, existing.offset));
      if (newChild != null) out.add(newChild);
      out.add(payload.sublist(existing.offset + existing.size));
    }
    return out.toBytes();
  }

  // ── Chunk offset fixup ──

  /// True when [moov] sits before the first `mdat` in file order — the case
  /// where growing moov shifts the audio data and `stco`/`co64` must follow.
  static bool _moovIsBeforeMdat(List<_AtomHeader> topLevel, _AtomHeader moov) {
    for (final a in topLevel) {
      if (_typeEquals(a.type, _typeBytes('mdat'))) {
        return moov.offset < a.offset;
      }
    }
    return false; // no mdat (unusual) — nothing to shift
  }

  /// Adds [delta] to every entry of every `stco`/`co64` under [moovBytes].
  static Uint8List _shiftChunkOffsets(Uint8List moovBytes, int delta) {
    final bytes = Uint8List.fromList(moovBytes);
    // moov payload starts at 8.
    for (final trak in _parseChildren(bytes, 8, bytes.length, 0)
        .where((a) => _typeEquals(a.type, _typeBytes('trak')))) {
      final mdia = _singleChild(bytes, trak, 'mdia', 0);
      final minf = mdia == null ? null : _singleChild(bytes, mdia, 'minf', 0);
      final stbl = minf == null ? null : _singleChild(bytes, minf, 'stbl', 0);
      if (stbl == null) continue;
      final stco = _singleChild(bytes, stbl, 'stco', 0);
      if (stco != null) _shiftEntries(bytes, stco, delta, 4);
      final co64 = _singleChild(bytes, stbl, 'co64', 0);
      if (co64 != null) _shiftEntries(bytes, co64, delta, 8);
    }
    return bytes;
  }

  static _AtomHeader? _singleChild(
      Uint8List bytes, _AtomHeader parent, String type, int childrenStart) {
    final start = parent.offset + parent.headerSize + childrenStart;
    final end = parent.offset + parent.size;
    return _findByType(_parseChildren(bytes, start, end, 0), type);
  }

  /// Shifts the chunk-offset entries of one `stco` (4-byte) or `co64`
  /// (8-byte) atom by [delta]. Done in place on [bytes].
  static void _shiftEntries(
      Uint8List bytes, _AtomHeader atom, int delta, int entrySize) {
    // version/flags(4) + entry_count(4), then entries.
    final base = atom.offset + atom.headerSize;
    if (base + 8 > atom.offset + atom.size) return;
    final count = _readU32(bytes, base + 4);
    var pos = base + 8;
    for (var i = 0; i < count; i++) {
      if (pos + entrySize > atom.offset + atom.size) break;
      if (entrySize == 4) {
        _writeU32(bytes, pos, _readU32(bytes, pos) + delta);
      } else {
        _writeU64(bytes, pos, _readU64(bytes, pos) + delta);
      }
      pos += entrySize;
    }
  }

  // ── Verification ──

  /// Re-parses [bytes] (the temp file) and throws unless it is a sane MP4
  /// whose `©lyr` holds exactly [expectedText] (or is absent when null).
  static void _verifyTempFile(Uint8List bytes, String? expectedText) {
    if (AudioContainerReader.detect(bytes) != AudioContainer.mp4) {
      throw const FormatException('temp file is not MP4');
    }
    final topLevel = _parseChildren(bytes, 0, bytes.length, 0);
    if (_findByType(topLevel, 'moov') == null ||
        _findByType(topLevel, 'mdat') == null) {
      throw const FormatException('temp file missing moov/mdat');
    }
    final moov = _findByType(topLevel, 'moov')!;
    final moovPayload = bytes.sublist(
      moov.offset + moov.headerSize,
      moov.offset + moov.size,
    );
    final ilst = _childPayload(moovPayload, ['udta', 'meta', 'ilst']);
    String? found;
    if (ilst != null) {
      final children = _parseChildren(ilst, 0, ilst.length, 0);
      final lyr = _findByTypeBytes(children, _lyrType);
      if (lyr != null) found = _readLyrText(ilst, lyr);
    }
    if (found != expectedText) {
      throw FormatException(
        'temp file ©lyr mismatch (expected ${expectedText == null ? 'absent' : 'text'}, '
        'found ${found == null ? 'absent' : 'text'})',
      );
    }
  }

  /// Reads the UTF-8 text out of a `©lyr` atom's `data` child.
  static String? _readLyrText(Uint8List ilst, _AtomHeader lyr) {
    final payload = ilst.sublist(
      lyr.offset + lyr.headerSize,
      lyr.offset + lyr.size,
    );
    final children = _parseChildren(payload, 0, payload.length, 0);
    final data = _findByType(children, 'data');
    if (data == null) return null;
    // type(4) + locale(4), then text.
    final start = data.offset + data.headerSize + 8;
    final end = data.offset + data.size;
    if (start > end) return null;
    return utf8.decode(payload.sublist(start, end));
  }

  // ── Byte helpers ──

  static List<int> _typeBytes(String type) => type.codeUnits;

  static bool _typeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _readU32(Uint8List b, int offset) =>
      (b[offset] << 24) | (b[offset + 1] << 16) | (b[offset + 2] << 8) | b[offset + 3];

  static int _readU64(Uint8List b, int offset) =>
      (_readU32(b, offset) * 0x100000000) + _readU32(b, offset + 4);

  static void _writeU32(Uint8List b, int offset, int value) {
    b[offset] = (value >> 24) & 0xFF;
    b[offset + 1] = (value >> 16) & 0xFF;
    b[offset + 2] = (value >> 8) & 0xFF;
    b[offset + 3] = value & 0xFF;
  }

  static void _writeU64(Uint8List b, int offset, int value) {
    _writeU32(b, offset, value ~/ 0x100000000);
    _writeU32(b, offset + 4, value & 0xFFFFFFFF);
  }

  static Uint8List _u32(int value) {
    final b = Uint8List(4);
    _writeU32(b, 0, value);
    return b;
  }

  /// Turns an OS error into something the user can act on.
  static String _describeWriteFailure(Object e) {
    if (e is FileSystemException) {
      return switch (e.osError?.errorCode) {
        13 || 1 =>
          'Écriture refusée par Android. Autorisez l\'accès à tous les fichiers '
              'pour que Musync puisse modifier les tags.',
        28 =>
          'Stockage plein : l\'écriture sûre a besoin de place pour une copie '
              'temporaire du morceau.',
        _ => 'Écriture impossible : ${e.osError?.message ?? e.message}',
      };
    }
    return 'Écriture impossible : $e';
  }
}

class _AtomHeader {
  final int offset;
  final int size;
  final int headerSize;
  final List<int> type;

  const _AtomHeader({
    required this.offset,
    required this.size,
    required this.headerSize,
    required this.type,
  });
}

class _ChildRef {
  final Uint8List payload;
  final int offset;
  final int size;

  const _ChildRef({
    required this.payload,
    required this.offset,
    required this.size,
  });
}

/// One ilst child to replace ([atom]) or remove (null [atom]).
class _AtomChange {
  final List<int> type;
  final Uint8List? atom;

  const _AtomChange(this.type, this.atom);
}
