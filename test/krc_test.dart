// Tests du format KRC de Kugou : déchiffrement (XOR + zlib) et parse.
//
// Le KRC cité est un extrait réel, capturé en live le 2026-11-12
// (The Weeknd « Blinding Lights ») : en-têtes, ligne de titre à 0 ms,
// lignes de crédits avec ：, puis les vraies paroles mot à mot.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/providers/krc.dart';

/// Chiffre un texte KRC comme le fait Kugou : zlib, XOR avec la clé,
/// 4 octets d'en-tête, base64. Le miroir exact de [decryptKrc].
String encryptKrc(String text) {
  const key = [
    64,
    71,
    97,
    119,
    94,
    50,
    116,
    71,
    81,
    54,
    49,
    45,
    206,
    210,
    110,
    105,
  ];
  final compressed = ZLibEncoder().convert(utf8.encode(text));
  final xored = List<int>.generate(
    compressed.length,
    (i) => compressed[i] ^ key[i % key.length],
  );
  return base64Encode([0, 0, 0, 0, ...xored]);
}

/// Un KRC réel (début de « Blinding Lights », 2026-11-12) : en-têtes,
/// ligne de titre, crédits, puis trois vraies lignes mot à mot.
const realKrc = '[ti:Blinding Lights]\n'
    '[ar:The Weeknd]\n'
    '[al:Blinding Lights]\n'
    '[by:]\n'
    '[offset:0]\n'
    '[language:xxx]\n'
    '[0,1756]<0,439,0>Blinding <439,439,0>Lights - <878,439,0>The <1317,439,0>Weeknd\n'
    '[1757,4829]<0,439,0>Lyrics <439,439,0>by：<878,439,0>Max <1317,439,0>Martin\n'
    '[6587,4829]<0,439,0>Composed <439,439,0>by：<878,439,0>Max <1317,439,0>Martin\n'
    '[14075,13597]<0,177,0>Yeah\n'
    '[27672,2784]<0,200,0>I\'ve <200,144,0>been <344,176,0>tryna <520,632,0>call\n'
    '[30456,2720]<0,184,0>I\'ve <184,177,0>been <361,191,0>on <552,176,0>my <728,273,0>own <1001,239,0>for <1240,352,0>long\n';

void main() {
  group('decryptKrc', () {
    test('aller-retour : le texte chiffré se déchiffre', () {
      expect(decryptKrc(encryptKrc(realKrc)), realKrc);
    });

    test('base64 invalide : null', () {
      expect(decryptKrc('!!!pas-du-base64!!!'), isNull);
    });

    test('trop court pour tenir un en-tête : null', () {
      expect(decryptKrc(base64Encode([1, 2, 3])), isNull);
    });

    test('zlib invalide : null', () {
      expect(decryptKrc(base64Encode([0, 0, 0, 0, 1, 2, 3, 4])), isNull);
    });
  });

  group('parseKrcLyrics', () {
    test('extrait réel : titre et crédits écartés, 3 lignes mot à mot', () {
      final lines = parseKrcLyrics(
        realKrc,
        song: 'Blinding Lights',
        singer: 'The Weeknd',
      );
      expect(lines, isNotNull);
      expect(lines!.map((l) => l.text), [
        'Yeah',
        "I've been tryna call",
        "I've been on my own for long",
      ]);
      expect(lines[0].timestamp, const Duration(milliseconds: 14075));
      expect(lines[0].words, hasLength(1));
      expect(lines[0].words[0].start, const Duration(milliseconds: 14075));
      expect(lines[0].words[0].duration, const Duration(milliseconds: 177));
      // Les décalages des mots sont absolus (ligne + décalage). Le texte
      // d'un mot garde son espace finale : c'est elle qui sépare les mots
      // quand la ligne est recomposée (comme les spans TTML).
      expect(lines[1].words[1].start, const Duration(milliseconds: 27872));
      expect(lines[1].words[1].text, 'been ');
    });

    test('ligne de titre conservée si le morceau ne correspond pas', () {
      final lines = parseKrcLyrics(
        realKrc,
        song: 'Autre titre',
        singer: 'Autre artiste',
      );
      expect(lines, isNotNull);
      expect(lines!.first.text, 'Blinding Lights - The Weeknd');
      expect(lines.first.timestamp, Duration.zero);
    });

    test('moins de 3 lignes : null', () {
      const two = '[14075,13597]<0,177,0>Yeah\n'
          '[27672,2784]<0,200,0>I\'ve <200,144,0>been\n';
      expect(
        parseKrcLyrics(two, song: 'Titre', singer: 'Artiste'),
        isNull,
      );
    });

    test('texte vide : null', () {
      expect(parseKrcLyrics('', song: 'Titre', singer: 'Artiste'), isNull);
    });

    test('que des crédits : null', () {
      const credits =
          '[1757,4829]<0,439,0>Lyrics <439,439,0>by：<878,439,0>Max\n'
          '[6587,4829]<0,439,0>Composed <439,439,0>by：<878,439,0>Max\n'
          '[11417,2634]<0,439,0>Produced <439,439,0>by：<878,439,0>Max\n';
      expect(
        parseKrcLyrics(credits, song: 'Titre', singer: 'Artiste'),
        isNull,
      );
    });
  });
}
