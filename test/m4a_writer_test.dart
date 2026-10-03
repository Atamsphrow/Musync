import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/m4a_writer.dart';
import 'package:musync/core/id3/id3_reader.dart';

// ── Synthetic M4A builder ──
//
// Minimal valid structure:
//
//   ftyp
//   moov
//     trak > mdia > minf > stbl > stco (2 entries: 1000, 2000)
//     udta > meta > ilst (empty, or with a pre-existing ©lyr)
//   mdat (100 bytes of dummy audio)
//
// moov sits before mdat, so growing moov must shift the stco entries.

Uint8List _u32(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.big);
  return b.buffer.asUint8List();
}

Uint8List _atom(String type, Uint8List payload) {
  final out = BytesBuilder(copy: false)
    ..add(_u32(8 + payload.length))
    ..add(type.codeUnits)
    ..add(payload);
  return out.toBytes();
}

Uint8List _stcoAtom(List<int> entries) {
  final body = BytesBuilder(copy: false)
    ..add(_u32(0)) // version/flags
    ..add(_u32(entries.length));
  for (final e in entries) {
    body.add(_u32(e));
  }
  return _atom('stco', body.toBytes());
}

Uint8List _lyrAtom(String text) {
  final textBytes = utf8.encode(text);
  final data = BytesBuilder(copy: false)
    ..add(_u32(16 + textBytes.length))
    ..add('data'.codeUnits)
    ..add(_u32(1)) // UTF-8
    ..add(_u32(0)) // locale
    ..add(textBytes);
  final lyr = BytesBuilder(copy: false)
    ..add(_u32(8 + data.length))
    ..add([0xA9, 0x6C, 0x79, 0x72])
    ..add(data.toBytes());
  return lyr.toBytes();
}

/// Builds a synthetic M4A. [existingLyr] pre-populates ©lyr; [withUdta]
/// controls whether the udta/meta/ilst chain exists at all.
Uint8List buildM4a({String? existingLyr, bool withUdta = true}) {
  final stbl = _atom('stbl', _stcoAtom([1000, 2000]));
  final minf = _atom('minf', stbl);
  final mdia = _atom('mdia', minf);
  final trak = _atom('trak', mdia);

  Uint8List moovPayload = trak;
  if (withUdta) {
    Uint8List ilstPayload = Uint8List(0);
    if (existingLyr != null) ilstPayload = _lyrAtom(existingLyr);
    final ilst = _atom('ilst', ilstPayload);
    final metaPayload = BytesBuilder(copy: false)
      ..add(_u32(0)) // version/flags
      ..add(ilst);
    final meta = _atom('meta', metaPayload.toBytes());
    final udta = _atom('udta', meta);
    moovPayload = Uint8List.fromList([...trak, ...udta]);
  }
  final moov = _atom('moov', moovPayload);

  final ftypPayload = BytesBuilder(copy: false)
    ..add('isom'.codeUnits)
    ..add(_u32(0))
    ..add('isom'.codeUnits);
  final ftyp = _atom('ftyp', ftypPayload.toBytes());

  final mdat = _atom('mdat', Uint8List(100)); // dummy audio

  final out = BytesBuilder(copy: false)
    ..add(ftyp)
    ..add(moov)
    ..add(mdat);
  return out.toBytes();
}

// ── Test helpers: re-parse the written file ──

int _readU32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// Finds a direct child atom; returns its payload range or null.
(Uint8List, int, int)? _findChild(
    Uint8List bytes, int payloadStart, int payloadEnd, List<int> wantType,
    {int skip = 0}) {
  var o = payloadStart + skip;
  while (o + 8 <= payloadEnd) {
    final size = _readU32(bytes, o);
    final type = bytes.sublist(o + 4, o + 8);
    if (size < 8 || o + size > payloadEnd) break;
    var match = true;
    for (var i = 0; i < 4; i++) {
      if (type[i] != wantType[i]) match = false;
    }
    if (match) return (bytes, o, size);
    o += size;
  }
  return null;
}

final _lyrType = [0xA9, 0x6C, 0x79, 0x72];

/// Reads the ©lyr text from a file, or null if absent.
String? readLyr(Uint8List bytes) {
  // top-level moov
  final moov = _findChild(bytes, 0, bytes.length, 'moov'.codeUnits);
  if (moov == null) return null;
  final (_, moovOff, moovSize) = moov;
  final udta = _findChild(
      bytes, moovOff + 8, moovOff + moovSize, 'udta'.codeUnits);
  if (udta == null) return null;
  final (_, udtaOff, udtaSize) = udta;
  final meta = _findChild(
      bytes, udtaOff + 8, udtaOff + udtaSize, 'meta'.codeUnits);
  if (meta == null) return null;
  final (_, metaOff, metaSize) = meta;
  final ilst = _findChild(
      bytes, metaOff + 12, metaOff + metaSize, 'ilst'.codeUnits);
  if (ilst == null) return null;
  final (_, ilstOff, ilstSize) = ilst;
  final lyr =
      _findChild(bytes, ilstOff + 8, ilstOff + ilstSize, _lyrType);
  if (lyr == null) return null;
  final (_, lyrOff, lyrSize) = lyr;
  final data = _findChild(
      bytes, lyrOff + 8, lyrOff + lyrSize, 'data'.codeUnits);
  if (data == null) return null;
  final (_, dataOff, dataSize) = data;
  // skip type(4) + locale(4)
  return utf8.decode(bytes.sublist(dataOff + 16, dataOff + dataSize));
}

/// Reads stco entries from a file.
List<int> readStco(Uint8List bytes) {
  final moov = _findChild(bytes, 0, bytes.length, 'moov'.codeUnits)!;
  final (_, moovOff, moovSize) = moov;
  final trak = _findChild(
      bytes, moovOff + 8, moovOff + moovSize, 'trak'.codeUnits)!;
  final (_, trakOff, trakSize) = trak;
  final mdia = _findChild(
      bytes, trakOff + 8, trakOff + trakSize, 'mdia'.codeUnits)!;
  final (_, mdiaOff, mdiaSize) = mdia;
  final minf = _findChild(
      bytes, mdiaOff + 8, mdiaOff + mdiaSize, 'minf'.codeUnits)!;
  final (_, minfOff, minfSize) = minf;
  final stbl = _findChild(
      bytes, minfOff + 8, minfOff + minfSize, 'stbl'.codeUnits)!;
  final (_, stblOff, stblSize) = stbl;
  final stco = _findChild(
      bytes, stblOff + 8, stblOff + stblSize, 'stco'.codeUnits)!;
  final (_, stcoOff, stcoSize) = stco;
  final count = _readU32(bytes, stcoOff + 12);
  return [
    for (var i = 0; i < count; i++) _readU32(bytes, stcoOff + 16 + i * 4)
  ];
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('m4a_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> writeTemp(Uint8List bytes) async {
    final f = File('${tmp.path}/test.m4a');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  test('round-trip: writes ©lyr and reads it back', () async {
    final path = await writeTemp(buildM4a());
    await M4aWriter.writeLrc(path, '[00:10.00]Hello');
    final bytes = await File(path).readAsBytes();
    expect(readLyr(bytes), '[00:10.00]Hello');
  });

  test('creates the udta/meta/ilst chain when missing', () async {
    final path = await writeTemp(buildM4a(withUdta: false));
    await M4aWriter.writeLrc(path, 'plain lyrics');
    final bytes = await File(path).readAsBytes();
    expect(readLyr(bytes), 'plain lyrics');
  });

  test('replaces an existing ©lyr', () async {
    final path = await writeTemp(buildM4a(existingLyr: 'old text'));
    await M4aWriter.writeLrc(path, '[00:20.00]new text');
    final bytes = await File(path).readAsBytes();
    expect(readLyr(bytes), '[00:20.00]new text');
  });

  test('null removes the ©lyr atom', () async {
    final path = await writeTemp(buildM4a(existingLyr: 'old text'));
    await M4aWriter.writeLrc(path, null);
    final bytes = await File(path).readAsBytes();
    expect(readLyr(bytes), isNull);
  });

  test('stco entries shift when moov grows in front of mdat', () async {
    final path = await writeTemp(buildM4a());
    final before = await File(path).readAsBytes();
    final moovBefore = _findChild(before, 0, before.length, 'moov'.codeUnits)!;
    final (_, _, moovSizeBefore) = moovBefore;

    // Write lyrics long enough to grow moov.
    await M4aWriter.writeLrc(path, 'x' * 500);

    final after = await File(path).readAsBytes();
    final moovAfter = _findChild(after, 0, after.length, 'moov'.codeUnits)!;
    final (_, _, moovSizeAfter) = moovAfter;
    final delta = moovSizeAfter - moovSizeBefore;
    expect(delta, greaterThan(0));

    final entries = readStco(after);
    expect(entries, [1000 + delta, 2000 + delta]);
  });

  test('mdat payload is byte-identical after write', () async {
    final path = await writeTemp(buildM4a());
    final before = await File(path).readAsBytes();
    // mdat is the last atom; capture its payload.
    final mdatBefore = _findChild(before, 0, before.length, 'mdat'.codeUnits)!;
    final (_, mdatOffB, mdatSizeB) = mdatBefore;
    final payloadBefore = before.sublist(mdatOffB + 8, mdatOffB + mdatSizeB);

    await M4aWriter.writeLrc(path, '[00:10.00]Hello');

    final after = await File(path).readAsBytes();
    final mdatAfter = _findChild(after, 0, after.length, 'mdat'.codeUnits)!;
    final (_, mdatOffA, mdatSizeA) = mdatAfter;
    final payloadAfter = after.sublist(mdatOffA + 8, mdatOffA + mdatSizeA);

    expect(payloadAfter, payloadBefore);
  });

  test('original untouched when the file is not a valid MP4', () async {
    final path = await writeTemp(buildM4a());
    final before = await File(path).readAsBytes();
    // Corrupt the ftyp so detection fails.
    final corrupt = Uint8List.fromList(before)..[4] = 0x00;
    await File(path).writeAsBytes(corrupt, flush: true);

    await expectLater(
      M4aWriter.writeLrc(path, 'lyrics'),
      throwsA(isA<M4aWriteException>()),
    );

    // Original (corrupt) bytes unchanged; no temp file left behind.
    expect(await File(path).readAsBytes(), corrupt);
    expect(await File('$path.musync.tmp').exists(), isFalse);
  });

  test('original untouched when moov is missing', () async {
    // ftyp + mdat only — no moov.
    final ftyp = _atom('ftyp', Uint8List.fromList([...'isom'.codeUnits, ..._u32(0), ...'isom'.codeUnits]));
    final mdat = _atom('mdat', Uint8List(50));
    final bytes = Uint8List.fromList([...ftyp, ...mdat]);
    final path = await writeTemp(bytes);

    await expectLater(
      M4aWriter.writeLrc(path, 'lyrics'),
      throwsA(isA<M4aWriteException>()),
    );
    expect(await File(path).readAsBytes(), bytes);
  });

  test('unicode lyrics survive the round-trip', () async {
    final path = await writeTemp(buildM4a());
    const text = '[00:10.70]Joé — cœur ♥';
    await M4aWriter.writeLrc(path, text);
    final bytes = await File(path).readAsBytes();
    expect(readLyr(bytes), text);
  });

  test('newly created meta contains the hdlr iTunes expects', () async {
    // No udta at all -> the writer builds udta > meta > ilst from scratch.
    final path = await writeTemp(buildM4a(withUdta: false));
    await M4aWriter.writeLrc(path, 'lyrics');
    final bytes = await File(path).readAsBytes();

    final moov = _findChild(bytes, 0, bytes.length, 'moov'.codeUnits)!;
    final (_, moovOff, moovSize) = moov;
    final udta =
        _findChild(bytes, moovOff + 8, moovOff + moovSize, 'udta'.codeUnits)!;
    final (_, udtaOff, udtaSize) = udta;
    final meta =
        _findChild(bytes, udtaOff + 8, udtaOff + udtaSize, 'meta'.codeUnits)!;
    final (_, metaOff, metaSize) = meta;
    // meta children start after 4 version/flags bytes; hdlr must be there
    // and declare the mdir (metadata) handler.
    final hdlr =
        _findChild(bytes, metaOff + 12, metaOff + metaSize, 'hdlr'.codeUnits);
    expect(hdlr, isNotNull, reason: 'meta without hdlr');
    final (_, hdlrOff, _) = hdlr!;
    // handler_type sits at +16 from hdlr start (size+type+version/flags+pre_defined).
    final handlerType = bytes.sublist(hdlrOff + 16, hdlrOff + 20);
    expect(String.fromCharCodes(handlerType), 'mdir');
  });

  test('Id3Reader reads back M4A lyrics written by M4aWriter', () async {
    final path = await writeTemp(buildM4a());
    const lrc = '[00:10.00]Hello\n[00:20.00]World';
    await M4aWriter.writeLrc(path, lrc);
    final pair = await Id3Reader.readLyricsFrames(path);
    expect(pair.synced, isNotNull);
    expect(pair.synced!.lines.length, 2);
    expect(pair.synced!.lines[0].text, 'Hello');
    expect(pair.synced!.lines[1].text, 'World');
  });

  test('Id3Reader returns no lyrics for M4A without clyr', () async {
    final path = await writeTemp(buildM4a());
    final pair = await Id3Reader.readLyricsFrames(path);
    expect(pair.synced, isNull);
    expect(pair.unsynced, isNull);
  });

  test('custom atom with binary type does not hide the existing udta', () async {
    // A weird-but-valid top-level atom before moov's udta: the parser must
    // skip it, not stop, or it would create a duplicate udta.
    Uint8List weirdAtom() {
      final payload = Uint8List.fromList(List.filled(20, 0xAB));
      final out = BytesBuilder(copy: false)
        ..add(_u32(8 + payload.length))
        ..add([0x00, 0x41, 0x42, 0x43]) // non-ASCII leading byte
        ..add(payload);
      return out.toBytes();
    }

    final base = buildM4a(existingLyr: 'keep me');
    // Insert the weird atom at the start of moov's payload.
    final moov = _findChild(base, 0, base.length, 'moov'.codeUnits)!;
    final (_, moovOff, moovSize) = moov;
    final weird = weirdAtom();
    final patched = BytesBuilder(copy: false)
      ..add(base.sublist(0, moovOff + 8))
      ..add(weird)
      ..add(base.sublist(moovOff + 8, moovOff + moovSize))
      ..add(base.sublist(moovOff + moovSize));
    // Fix the moov size.
    final patchedBytes = patched.toBytes();
    final newMoovSize = moovSize + weird.length;
    patchedBytes[moovOff] = (newMoovSize >> 24) & 0xFF;
    patchedBytes[moovOff + 1] = (newMoovSize >> 16) & 0xFF;
    patchedBytes[moovOff + 2] = (newMoovSize >> 8) & 0xFF;
    patchedBytes[moovOff + 3] = newMoovSize & 0xFF;

    final path = await writeTemp(patchedBytes);
    await M4aWriter.writeLrc(path, 'new text');
    final bytes = await File(path).readAsBytes();
    expect(readLyr(bytes), 'new text');

    // Exactly one udta: the pre-existing one was found and reused.
    final moov2 = _findChild(bytes, 0, bytes.length, 'moov'.codeUnits)!;
    final (_, moovOff2, moovSize2) = moov2;
    var udtaCount = 0;
    var off = moovOff2 + 8;
    while (off + 8 <= moovOff2 + moovSize2) {
      final size = ByteData.sublistView(bytes, off, off + 4)
          .getUint32(0, Endian.big);
      if (size < 8 || off + size > moovOff2 + moovSize2) break;
      if (String.fromCharCodes(bytes.sublist(off + 4, off + 8)) == 'udta') {
        udtaCount++;
      }
      off += size;
    }
    expect(udtaCount, 1, reason: 'duplicate udta created');
  });
}
