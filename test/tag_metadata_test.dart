// Tests for Id3Reader.readMetadataFromBytes: parsing TIT2/TPE1/TALB
// straight from the tag bytes.
//
// Tag fixtures are assembled byte by byte, not through Id3Tag.build, so a bug
// shared by the writer and the parser can't hide behind a round trip.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_tag.dart';

/// A text frame body: one encoding byte, then the text.
Uint8List _textBody(String text, int encoding) {
  final encoded = Id3Tag.encodeText(text, encoding);
  return Uint8List.fromList([encoding, ...encoded]);
}

/// Minimal v2.3 tag: header + frames with big-endian sizes, tag size
/// synchsafe — the way a real v2.3 tagger lays it out.
Uint8List _tagBytes(List<MapEntry<String, Uint8List>> frames) {
  final body = BytesBuilder();
  for (final frame in frames) {
    final size = frame.value.length;
    body.add(ascii.encode(frame.key));
    body.add([
      (size >> 24) & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 8) & 0xFF,
      size & 0xFF,
    ]);
    body.add([0, 0]); // frame flags
    body.add(frame.value);
  }
  final bodyBytes = body.toBytes();
  return (BytesBuilder()
        ..add(ascii.encode('ID3'))
        ..add([3, 0, 0])
        ..add([
          (bodyBytes.length >> 21) & 0x7F,
          (bodyBytes.length >> 14) & 0x7F,
          (bodyBytes.length >> 7) & 0x7F,
          bodyBytes.length & 0x7F,
        ])
        ..add(bodyBytes))
      .toBytes();
}

void main() {
  group('Id3Reader.readMetadataFromBytes', () {
    test('parses TIT2/TPE1/TALB', () {
      final bytes = _tagBytes([
        MapEntry('TIT2', _textBody("A trop t'aimer", Id3Encoding.utf8)),
        MapEntry('TPE1', _textBody('Jo\u00e9 Dw\u00e8t Fil\u00e9', Id3Encoding.utf8)),
        MapEntry('TALB', _textBody('Mon album', Id3Encoding.utf8)),
      ]);
      final meta = Id3Reader.readMetadataFromBytes(bytes);
      expect(meta.title, "A trop t'aimer");
      expect(meta.artist, 'Jo\u00e9 Dw\u00e8t Fil\u00e9');
      expect(meta.album, 'Mon album');
    });

    test('decodes UTF-16 and Latin-1 text frames', () {
      final bytes = _tagBytes([
        MapEntry('TIT2', _textBody('Pr\u00e9f\u00e9r\u00e9', Id3Encoding.utf16WithBom)),
        // Latin-1 bytes for Caf\u00e9: the smart decoder must not mojibake them.
        MapEntry(
          'TPE1',
          Uint8List.fromList([Id3Encoding.latin1, 0x43, 0x61, 0x66, 0xE9]),
        ),
      ]);
      final meta = Id3Reader.readMetadataFromBytes(bytes);
      expect(meta.title, 'Pr\u00e9f\u00e9r\u00e9');
      expect(meta.artist, 'Caf\u00e9');
      expect(meta.album, isNull);
    });

    test('missing frames come back null', () {
      final bytes = _tagBytes([
        MapEntry('TIT2', _textBody('Only title', Id3Encoding.utf8)),
      ]);
      final meta = Id3Reader.readMetadataFromBytes(bytes);
      expect(meta.title, 'Only title');
      expect(meta.artist, isNull);
      expect(meta.album, isNull);
    });

    test('no ID3 tag comes back all null', () {
      final meta = Id3Reader.readMetadataFromBytes(
        Uint8List.fromList([1, 2, 3, 4, 5]),
      );
      expect(meta.title, isNull);
      expect(meta.artist, isNull);
      expect(meta.album, isNull);
    });

    test('blank text counts as absent', () {
      final bytes = _tagBytes([
        MapEntry('TIT2', _textBody('   ', Id3Encoding.utf8)),
        MapEntry('TPE1', _textBody('Artist', Id3Encoding.utf8)),
      ]);
      final meta = Id3Reader.readMetadataFromBytes(bytes);
      expect(meta.title, isNull);
      expect(meta.artist, 'Artist');
    });
  });

  group('Id3Reader.readMetadata', () {
    test('walks the file and steps over artwork', () async {
      final dir = await Directory.systemTemp.createTemp('musync_meta');
      try {
        // 200 kB of fake artwork ahead of the text frames: the walk must skip
        // it by seeking, not by reading it.
        final art = List<int>.filled(200 * 1024, 0xAB);
        final tag = _tagBytes([
          MapEntry('APIC', Uint8List.fromList([0, ...art])),
          MapEntry('TIT2', _textBody('Past the artwork', Id3Encoding.utf8)),
          MapEntry('TPE1', _textBody('Artist', Id3Encoding.utf8)),
          MapEntry('TALB', _textBody('Album', Id3Encoding.utf8)),
        ]);
        final file = File('${dir.path}/song.mp3');
        await file.writeAsBytes([...tag, ...List<int>.filled(1024, 0)]);

        final meta = await Id3Reader.readMetadata(file.path);
        expect(meta.title, 'Past the artwork');
        expect(meta.artist, 'Artist');
        expect(meta.album, 'Album');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('missing file yields nulls, not an exception', () async {
      final meta = await Id3Reader.readMetadata(
        '/nonexistent/musync_test_song.mp3',
      );
      expect(meta.title, isNull);
      expect(meta.artist, isNull);
      expect(meta.album, isNull);
    });

    test('file without ID3 yields nulls', () async {
      final dir = await Directory.systemTemp.createTemp('musync_meta');
      try {
        final file = File('${dir.path}/plain.mp3');
        await file.writeAsBytes(List<int>.filled(1024, 0x11));
        final meta = await Id3Reader.readMetadata(file.path);
        expect(meta.title, isNull);
        expect(meta.artist, isNull);
        expect(meta.album, isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

}
