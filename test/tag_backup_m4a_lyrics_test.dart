// Prérequis P8 (audit) : la sauvegarde ©lyr des M4A dans TagBackupStore.
//
// Avant P8, `capture()` répondait `false` pour tout MP4 : aucune annulation
// possible des paroles écrites dans un M4A. Depuis P8, le texte ©lyr courant
// est copié dans un blob `.lyr`, et `restore()` le réécrit via M4aWriter.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/m4a_writer.dart';
import 'package:musync/core/id3/tag_backup.dart';

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
    ..add(_u32(0))
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
    ..add(_u32(1))
    ..add(_u32(0))
    ..add(textBytes);
  final lyr = BytesBuilder(copy: false)
    ..add(_u32(8 + data.length))
    ..add([0xA9, 0x6C, 0x79, 0x72])
    ..add(data.toBytes());
  return lyr.toBytes();
}

/// M4A minimal : ftyp + moov (trak/stco + udta/meta/ilst) + mdat.
Uint8List _buildM4a({String? existingLyr}) {
  final stbl = _atom('stbl', _stcoAtom([1000, 2000]));
  final minf = _atom('minf', stbl);
  final mdia = _atom('mdia', minf);
  final trak = _atom('trak', mdia);

  Uint8List ilstPayload = Uint8List(0);
  if (existingLyr != null) ilstPayload = _lyrAtom(existingLyr);
  final ilst = _atom('ilst', ilstPayload);
  final metaPayload = BytesBuilder(copy: false)
    ..add(_u32(0))
    ..add(ilst);
  final meta = _atom('meta', metaPayload.toBytes());
  final udta = _atom('udta', meta);
  final moov = _atom('moov', Uint8List.fromList([...trak, ...udta]));

  final ftypPayload = BytesBuilder(copy: false)
    ..add('isom'.codeUnits)
    ..add(_u32(0))
    ..add('isom'.codeUnits);
  final ftyp = _atom('ftyp', ftypPayload.toBytes());
  final mdat = _atom('mdat', Uint8List(100));

  final out = BytesBuilder(copy: false)
    ..add(ftyp)
    ..add(moov)
    ..add(mdat);
  return out.toBytes();
}

void main() {
  late Directory tmp;
  late Directory root;
  late TagBackupStore store;
  late File m4a;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tag_backup_m4a_');
    root = Directory('${tmp.path}/support')..createSync();
    store = TagBackupStore(root: root);
    m4a = File('${tmp.path}/test.m4a');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('capture M4A avec ©lyr puis restore remet les anciennes paroles', () async {
    await m4a.writeAsBytes(_buildM4a(existingLyr: '[00:01.00]Anciennes'));
    expect(await store.capture(m4a.path), isTrue);
    expect(await store.backupFor(m4a.path), isNotNull);

    await M4aWriter.writeLrc(m4a.path, '[00:01.00]Nouvelles');
    await store.markWritten(m4a.path);
    expect(await M4aWriter.readLrc(m4a.path), '[00:01.00]Nouvelles');

    await store.restore(m4a.path);
    expect(await M4aWriter.readLrc(m4a.path), '[00:01.00]Anciennes');
    // L'étape est consommée : plus rien à annuler.
    expect(await store.backupFor(m4a.path), isNull);
  });

  test('capture M4A sans ©lyr puis restore supprime les paroles écrites', () async {
    await m4a.writeAsBytes(_buildM4a());
    expect(await M4aWriter.readLrc(m4a.path), isNull);
    expect(await store.capture(m4a.path), isTrue);

    await M4aWriter.writeLrc(m4a.path, '[00:01.00]Nouvelles');
    await store.markWritten(m4a.path);
    expect(await M4aWriter.readLrc(m4a.path), isNotNull);

    await store.restore(m4a.path);
    expect(await M4aWriter.readLrc(m4a.path), isNull);
  });

  test('capture M4A deux fois : undo remonte d\'un cran, pas deux', () async {
    await m4a.writeAsBytes(_buildM4a(existingLyr: '[00:01.00]V1'));
    expect(await store.capture(m4a.path), isTrue);
    await M4aWriter.writeLrc(m4a.path, '[00:01.00]V2');
    await store.markWritten(m4a.path);
    expect(await store.capture(m4a.path), isTrue);
    await M4aWriter.writeLrc(m4a.path, '[00:01.00]V3');
    await store.markWritten(m4a.path);

    await store.restore(m4a.path);
    expect(await M4aWriter.readLrc(m4a.path), '[00:01.00]V2');
    await store.restore(m4a.path);
    expect(await M4aWriter.readLrc(m4a.path), '[00:01.00]V1');
  });
}
