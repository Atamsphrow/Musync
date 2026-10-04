// Tests for the tag-editor metadata writers (F2).
//
// The fixtures are assembled byte by byte rather than through the writers
// themselves, so a bug shared by the writer and the parser can't hide behind
// a round trip.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_tag.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/m4a_writer.dart';
import 'package:musync/core/id3/tag_metadata.dart';

Uint8List _u32(int v) => Uint8List.fromList([
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ]);

/// A text frame the way a real tagger writes it: v2.4, UTF-8.
Uint8List _textFrame(String id, String text) {
  final textBytes = utf8.encode(text);
  final body = Uint8List.fromList([3, ...textBytes]);
  final size = body.length;
  return Uint8List.fromList([
    ...ascii.encode(id),
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
    0,
    0,
    ...body,
  ]);
}

/// COMM frame: encoding, language, empty descriptor, text.
Uint8List _commFrame(String text) {
  final textBytes = utf8.encode(text);
  final body = Uint8List.fromList([3, 0x65, 0x6E, 0x67, 0, ...textBytes]);
  final size = body.length;
  return Uint8List.fromList([
    ...ascii.encode('COMM'),
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
    0,
    0,
    ...body,
  ]);
}

/// APIC frame: latin-1, mime, front cover, empty description, image bytes.
Uint8List _apicFrame(Uint8List image, {String mime = 'image/jpeg'}) {
  final body = Uint8List.fromList([
    0,
    ...ascii.encode(mime),
    0,
    3,
    0,
    ...image,
  ]);
  final size = body.length;
  return Uint8List.fromList([
    ...ascii.encode('APIC'),
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
    0,
    0,
    ...body,
  ]);
}

Uint8List _mp3(List<int> frames) {
  final body = Uint8List.fromList(frames);
  final size = body.length;
  final audio = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    4,
    0,
    0,
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
    ...body,
    ...audio,
  ]);
}

// ── Minimal M4A fixture ──

Uint8List _atom(String type, Uint8List payload) => Uint8List.fromList([
      ..._u32(8 + payload.length),
      ...ascii.encode(type),
      ...payload,
    ]);

Uint8List _dataAtom(Uint8List content, {int kind = 1}) => Uint8List.fromList([
      ..._u32(16 + content.length),
      ...ascii.encode('data'),
      ..._u32(kind),
      ..._u32(0),
      ...content,
    ]);

Uint8List _textAtom(List<int> type, String text) =>
    _makeAtomBytes(type, _dataAtom(Uint8List.fromList(utf8.encode(text))));

Uint8List _makeAtomBytes(List<int> type, Uint8List payload) =>
    Uint8List.fromList([
      ..._u32(8 + payload.length),
      ...type,
      ...payload,
    ]);

Uint8List _m4a({List<int> ilstChildren = const []}) {
  final ilst = _atom('ilst', Uint8List.fromList(ilstChildren));
  final meta = _atom(
    'meta',
    Uint8List.fromList([..._u32(0), ...ilst]),
  );
  final udta = _atom('udta', meta);
  final moov = _atom('moov', udta);
  final ftyp = _atom(
    'ftyp',
    Uint8List.fromList(
        [...ascii.encode('isom'), ..._u32(0), ...ascii.encode('isom')]),
  );
  final mdat = _atom('mdat', Uint8List(128));
  return Uint8List.fromList([...ftyp, ...moov, ...mdat]);
}

/// Builds a TrackMetadata diff with only the given fields set.
TrackMetadata _m({
  String? title,
  String? artist,
  String? album,
  String? albumArtist,
  String? genre,
  String? year,
  int? trackNumber,
  int? trackTotal,
  int? discNumber,
  int? discTotal,
  String? composer,
  String? comment,
  Uint8List? artwork,
}) => (
  title: title,
  artist: artist,
  album: album,
  albumArtist: albumArtist,
  genre: genre,
  year: year,
  trackNumber: trackNumber,
  trackTotal: trackTotal,
  discNumber: discNumber,
  discTotal: discTotal,
  composer: composer,
  comment: comment,
  artwork: artwork,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_tagedit_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<File> fixture(String name, List<int> bytes) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  const full = (
    title: 'Titre accentué — été',
    artist: 'Artiste',
    album: 'Album',
    albumArtist: 'Artiste de l\'album',
    genre: 'Rock',
    year: '2024',
    trackNumber: 3,
    trackTotal: 12,
    discNumber: 1,
    discTotal: 2,
    composer: 'Compositeur',
    comment: 'Un commentaire',
    artwork: null,
  );

  group('Id3Writer.writeMetadata / Id3Reader.readFullMetadata', () {
    test('round-trips every field on a v2.4 tag', () async {
      final file = await fixture('full.mp3', _mp3([]));

      await Id3Writer.writeMetadata(file.path, full);
      final read = await Id3Reader.readFullMetadata(file.path);

      expect(read.title, 'Titre accentué — été');
      expect(read.artist, 'Artiste');
      expect(read.album, 'Album');
      expect(read.albumArtist, 'Artiste de l\'album');
      expect(read.genre, 'Rock');
      expect(read.year, '2024');
      expect(read.trackNumber, 3);
      expect(read.trackTotal, 12);
      expect(read.discNumber, 1);
      expect(read.discTotal, 2);
      expect(read.composer, 'Compositeur');
      expect(read.comment, 'Un commentaire');
      // The year went to TDRC on a v2.4 tag.
      final tag = Id3Tag.parse(await file.readAsBytes())!;
      expect(tag.frameById('TDRC'), isNotNull);
      expect(tag.frameById('TYER'), isNull);
    });

    test('leaves untouched fields and the audio alone', () async {
      final lyrics = _textFrame('USLT', 'some lyrics');
      final file = await fixture(
        'keep.mp3',
        _mp3([..._textFrame('TIT2', 'Ancien titre'), ...lyrics]),
      );
      final before = await file.readAsBytes();
      final audioBefore = before.sublist(Id3Tag.parse(before)!.audioOffset);

      await Id3Writer.writeMetadata(file.path, _m(artist: 'Nouvel artiste',));

      final read = await Id3Reader.readFullMetadata(file.path);
      expect(read.title, 'Ancien titre');
      expect(read.artist, 'Nouvel artiste');
      final after = await file.readAsBytes();
      final tag = Id3Tag.parse(after)!;
      expect(tag.frameById('USLT'), isNotNull);
      expect(after.sublist(tag.audioOffset), audioBefore);
    });

    test('empty string removes the frame', () async {
      final file = await fixture(
        'remove.mp3',
        _mp3([..._textFrame('TIT2', 'Titre'), ..._textFrame('TPE1', 'Artiste')]),
      );

      await Id3Writer.writeMetadata(file.path, _m(title: '',));

      final read = await Id3Reader.readFullMetadata(file.path);
      expect(read.title, isNull);
      expect(read.artist, 'Artiste');
      final tag = Id3Tag.parse(await file.readAsBytes())!;
      expect(tag.frameById('TIT2'), isNull);
    });

    test('negative number drops that part of the pair', () async {
      final file = await fixture(
        'pair.mp3',
        _mp3([..._textFrame('TRCK', '3/12')]),
      );

      // Drop the number, keep the total.
      await Id3Writer.writeMetadata(file.path, _m(trackNumber: -1,));
      var read = await Id3Reader.readFullMetadata(file.path);
      expect(read.trackNumber, isNull);
      expect(read.trackTotal, 12);

      // Drop both: the frame goes away.
      await Id3Writer.writeMetadata(file.path, _m(trackNumber: -1,
trackTotal: -1,));
      read = await Id3Reader.readFullMetadata(file.path);
      expect(read.trackNumber, isNull);
      expect(read.trackTotal, isNull);
      final tag = Id3Tag.parse(await file.readAsBytes())!;
      expect(tag.frameById('TRCK'), isNull);
    });

    test('reads COMM and APIC written by a real tagger', () async {
      final image = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]);
      final file = await fixture(
        'frames.mp3',
        _mp3([..._commFrame('hello'), ..._apicFrame(image)]),
      );

      final read = await Id3Reader.readFullMetadata(file.path);
      expect(read.comment, 'hello');
      expect(read.artwork, image);
    });

    test('replaces the cover and detects PNG', () async {
      final old = Uint8List.fromList([0xFF, 0xD8, 1, 2]);
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 5, 6]);
      final file = await fixture('cover.mp3', _mp3([..._apicFrame(old)]));

      await Id3Writer.writeMetadata(file.path, _m(artwork: png,));

      final read = await Id3Reader.readFullMetadata(file.path);
      expect(read.artwork, png);
      final tag = Id3Tag.parse(await file.readAsBytes())!;
      // A single APIC frame, declared as PNG.
      expect(tag.frames.where((f) => f.id == 'APIC').length, 1);
      final body = tag.frameById('APIC')!.decodedBody;
      final mimeEnd = body.indexOf(0, 1);
      expect(ascii.decode(body.sublist(1, mimeEnd)), 'image/png');
    });

    test('empty artwork removes the cover', () async {
      final file = await fixture(
        'nocover.mp3',
        _mp3([..._apicFrame(Uint8List.fromList([1, 2, 3]))]),
      );

      await Id3Writer.writeMetadata(file.path, _m(artwork: Uint8List(0),));

      final read = await Id3Reader.readFullMetadata(file.path);
      expect(read.artwork, isNull);
    });

    test('writes the year to TYER on a v2.3 tag', () async {
      // v2.3 tag header, big-endian frame sizes.
      final textBytes = utf8.encode('2020');
      final body = Uint8List.fromList([3, ...textBytes]);
      final size = body.length;
      final frame = Uint8List.fromList([
        ...ascii.encode('TYER'),
        (size >> 24) & 0xFF,
        (size >> 16) & 0xFF,
        (size >> 8) & 0xFF,
        size & 0xFF,
        0,
        0,
        ...body,
      ]);
      final tagSize = frame.length;
      final file = await fixture(
        'v23.mp3',
        Uint8List.fromList([
          ...ascii.encode('ID3'),
          3,
          0,
          0,
          (tagSize >> 21) & 0x7F,
          (tagSize >> 14) & 0x7F,
          (tagSize >> 7) & 0x7F,
          tagSize & 0x7F,
          ...frame,
          ...Uint8List(1024),
        ]),
      );

      await Id3Writer.writeMetadata(file.path, _m(year: '2021',));

      final read = await Id3Reader.readFullMetadata(file.path);
      expect(read.year, '2021');
      final tag = Id3Tag.parse(await file.readAsBytes())!;
      expect(tag.majorVersion, 3);
      expect(tag.frameById('TYER'), isNotNull);
      expect(tag.frameById('TDRC'), isNull);
    });

    test('refuses a container Musync cannot edit', () async {
      // FLAC magic.
      final file = await fixture(
        'nope.flac',
        Uint8List.fromList([...ascii.encode('fLaC'), ...Uint8List(64)]),
      );

      await expectLater(
        () => Id3Writer.writeMetadata(file.path, full),
        throwsA(
          isA<Id3WriteException>().having(
            (e) => e.message,
            'message',
            contains('Format non supporté'),
          ),
        ),
      );
      // Untouched.
      expect(await file.readAsBytes(), hasLength(68));
    });

    test('leaves no temp file behind', () async {
      final file = await fixture('clean.mp3', _mp3([]));
      await Id3Writer.writeMetadata(file.path, full);
      final leftovers =
          tempDir.listSync().where((e) => e.path.endsWith('.tmp')).toList();
      expect(leftovers, isEmpty);
    });
  });

  group('M4aWriter.writeMetadata / readMetadata', () {
    test('round-trips every field', () async {
      final file = await fixture('meta.m4a', _m4a());

      await M4aWriter.writeMetadata(file.path, full);
      final read = await M4aWriter.readMetadata(file.path);

      expect(read.title, 'Titre accentué — été');
      expect(read.artist, 'Artiste');
      expect(read.album, 'Album');
      expect(read.albumArtist, 'Artiste de l\'album');
      expect(read.genre, 'Rock');
      expect(read.year, '2024');
      expect(read.trackNumber, 3);
      expect(read.trackTotal, 12);
      expect(read.discNumber, 1);
      expect(read.discTotal, 2);
      expect(read.composer, 'Compositeur');
      expect(read.comment, 'Un commentaire');
    });

    test('creates the ilst chain when missing and reads back', () async {
      // moov without udta at all.
      final moov = _atom('moov', Uint8List(0));
      final ftyp = _atom(
        'ftyp',
        Uint8List.fromList(
            [...ascii.encode('isom'), ..._u32(0), ...ascii.encode('isom')]),
      );
      final mdat = _atom('mdat', Uint8List(64));
      final file = await fixture(
        'chain.m4a',
        Uint8List.fromList([...ftyp, ...moov, ...mdat]),
      );

      await M4aWriter.writeMetadata(file.path, _m(title: 'Nouveau',));

      final read = await M4aWriter.readMetadata(file.path);
      expect(read.title, 'Nouveau');
    });

    test('removes fields and keeps the rest', () async {
      final file = await fixture(
        'rm.m4a',
        _m4a(ilstChildren: [
          ..._textAtom([0xA9, 0x6E, 0x61, 0x6D], 'Titre'), // ©nam
          ..._textAtom([0xA9, 0x41, 0x52, 0x54], 'Artiste'), // ©ART
        ]),
      );

      await M4aWriter.writeMetadata(file.path, _m(title: '',
album: 'Album',));

      final read = await M4aWriter.readMetadata(file.path);
      expect(read.title, isNull);
      expect(read.artist, 'Artiste');
      expect(read.album, 'Album');
    });

    test('round-trips the cover', () async {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 9, 9]);
      final file = await fixture('covr.m4a', _m4a());

      await M4aWriter.writeMetadata(file.path, _m(artwork: png,));
      expect((await M4aWriter.readMetadata(file.path)).artwork, png);

      await M4aWriter.writeMetadata(file.path, _m(artwork: Uint8List(0),));
      expect((await M4aWriter.readMetadata(file.path)).artwork, isNull);
    });

    test('delegates through Id3Writer for M4A files', () async {
      final file = await fixture('via.m4a', _m4a());
      await Id3Writer.writeMetadata(file.path, _m(title: 'Via Id3Writer',
trackNumber: 7,));
      final read = await Id3Reader.readFullMetadata(file.path);
      expect(read.title, 'Via Id3Writer');
      expect(read.trackNumber, 7);
    });

    test('mdat payload is byte-identical after a metadata write', () async {
      final file = await fixture('mdat.m4a', _m4a());
      final before = await file.readAsBytes();
      await M4aWriter.writeMetadata(file.path, _m(title: 'x',));
      final after = await file.readAsBytes();

      Uint8List mdatOf(Uint8List bytes) {
        var o = 0;
        while (o + 8 <= bytes.length) {
          final size = (bytes[o] << 24) |
              (bytes[o + 1] << 16) |
              (bytes[o + 2] << 8) |
              bytes[o + 3];
          final type = ascii.decode(bytes.sublist(o + 4, o + 8));
          if (type == 'mdat') return bytes.sublist(o + 8, o + size);
          o += size;
        }
        throw StateError('no mdat');
      }

      expect(mdatOf(after), mdatOf(before));
    });
  });
}
