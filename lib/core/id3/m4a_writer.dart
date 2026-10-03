import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:musync/core/id3/audio_container.dart';

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

  // ── File assembly ──

  /// Returns the full new file bytes with the `©lyr` atom replaced/added (or
  /// removed when [text] is null).
  static Uint8List _buildFileWithLyrics(Uint8List bytes, String? text) {
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
    final newMoovPayload = _rebuildMoovPayload(moovPayload, text);
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

  /// Rebuilds the moov payload with an updated `udta > meta > ilst > ©lyr`
  /// chain. Creates any missing parent atoms.
  ///
  /// Empty parent atoms left behind by a removal are valid MP4 and harmless;
  /// pruning them would add risk for no benefit.
  static Uint8List _rebuildMoovPayload(Uint8List moovPayload, String? text) {
    final newLyr = text == null ? null : _buildLyrAtom(text);

    // Walk down, creating missing parents on the way when adding.
    final udtaRef = _childRef(moovPayload, 'udta', 0);
    if (udtaRef == null) {
      if (newLyr == null) return moovPayload; // nothing to remove
      final ilst = _makeAtom('ilst', newLyr);
      final meta = _makeAtom('meta', _buildMetaPayload(ilst));
      final udta = _makeAtom('udta', meta);
      return _rebuildWithChild(moovPayload, _typeBytes('udta'), udta, 0);
    }

    final metaRef = _childRef(udtaRef.payload, 'meta', 0);
    if (metaRef == null) {
      if (newLyr == null) return moovPayload;
      final ilst = _makeAtom('ilst', newLyr);
      final meta = _makeAtom('meta', _buildMetaPayload(ilst));
      final newUdtaPayload =
          _rebuildWithChild(udtaRef.payload, _typeBytes('meta'), meta, 0);
      return _rebuildWithChild(
          moovPayload, _typeBytes('udta'), _makeAtom('udta', newUdtaPayload), 0);
    }

    // meta's children start after 4 version/flags bytes.
    final ilstRef = _childRef(metaRef.payload, 'ilst', 4);
    if (ilstRef == null) {
      if (newLyr == null) return moovPayload;
      final ilst = _makeAtom('ilst', newLyr);
      final newMetaPayload =
          _rebuildWithChild(metaRef.payload, _typeBytes('ilst'), ilst, 4);
      final newUdtaPayload = _rebuildWithChild(udtaRef.payload,
          _typeBytes('meta'), _makeAtom('meta', newMetaPayload), 0);
      return _rebuildWithChild(
          moovPayload, _typeBytes('udta'), _makeAtom('udta', newUdtaPayload), 0);
    }

    final newIlstPayload = _rebuildWithChild(ilstRef.payload, _lyrType, newLyr, 0);
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
