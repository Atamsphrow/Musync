/// E26 : `_parseApicFrame` copiait la pochette par `sublistView` — une vue
/// sur le corps du tag, lui-même une vue sur le buffer entier lu. La pochette
/// stockée dans `TrackMetadata` retenait donc tout le tag en mémoire.
///
/// Le correctif copie les octets de l'image : le buffer de la pochette lue
/// doit être exactement l'image, pas le tag entier. Le test le prouve avec
/// un tag bourré de padding (4096 octets) autour d'une petite image (16 o).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';

/// Tag ID3v2.3 minimal : un cadre APIC + du padding, comme un vrai taggeur.
Uint8List _tagBytes() {
  final image = Uint8List.fromList(
    List<int>.generate(16, (i) => 0xA0 + i),
  );
  final body = BytesBuilder()
    ..add([0]) // encoding latin-1
    ..add(ascii.encode('image/jpeg'))
    ..add([0]) // fin MIME
    ..add([0x03]) // type : couverture avant
    ..add([0]) // description vide + terminateur
    ..add(image);
  final bodyBytes = body.toBytes();
  final frames = BytesBuilder()
    ..add(ascii.encode('APIC'))
    ..add([
      (bodyBytes.length >> 24) & 0xFF,
      (bodyBytes.length >> 16) & 0xFF,
      (bodyBytes.length >> 8) & 0xFF,
      bodyBytes.length & 0xFF,
    ])
    ..add([0, 0]) // flags
    ..add(bodyBytes)
    ..add(List<int>.filled(4096, 0)); // padding : le tag est bien plus gros
  final framesBytes = frames.toBytes();
  return (BytesBuilder()
        ..add(ascii.encode('ID3'))
        ..add([3, 0, 0])
        ..add([
          (framesBytes.length >> 21) & 0x7F,
          (framesBytes.length >> 14) & 0x7F,
          (framesBytes.length >> 7) & 0x7F,
          framesBytes.length & 0x7F,
        ])
        ..add(framesBytes))
      .toBytes();
}

void main() {
  test('la pochette lue ne retient pas le buffer du tag entier', () {
    final tagBytes = _tagBytes();
    final meta = Id3Reader.fullMetadataFromBytes(tagBytes);

    final artwork = meta.artwork;
    expect(artwork, isNotNull);
    expect(
      artwork,
      List<int>.generate(16, (i) => 0xA0 + i),
      reason: 'les octets de l’image doivent être intacts',
    );
    // Une vue (`sublistView`) partagerait le buffer du tag (~4 Ko) ;
    // une copie a un buffer exactement de la taille de l'image.
    expect(
      artwork!.buffer.lengthInBytes,
      artwork.length,
      reason: 'la pochette doit être une copie, pas une vue sur le tag',
    );
    expect(tagBytes.length, greaterThan(4000));
  });
}
