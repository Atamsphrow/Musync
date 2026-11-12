// Tests de l'alignement médian : recaler les timings d'un autre
// enregistrement sur ceux du fichier, ou les laisser tels quels quand
// l'écart n'est pas fiable.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/lyrics_align.dart';

SyncedLyrics lines(List<(int, String)> spec) => SyncedLyrics([
  for (final (ms, text) in spec)
    LyricLine(timestamp: Duration(milliseconds: ms), text: text),
]);

const texts = [
  'Première ligne du morceau',
  'Deuxième ligne du morceau',
  'Troisième ligne du morceau',
  'Quatrième ligne du morceau',
];

void main() {
  group('alignLyrics', () {
    test('décalage constant : tout est décalé de la médiane', () {
      final incoming = lines([
        (4000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
        (22000, texts[3]),
      ]);
      final reference = lines([
        (6000, texts[0]),
        (12000, texts[1]),
        (18000, texts[2]),
        (24000, texts[3]),
      ]);
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isTrue);
      expect(result.shiftMs, 2000);
      expect(result.lyrics.lines.map((l) => l.timestamp!.inMilliseconds),
          [6000, 12000, 18000, 24000]);
    });

    test('les mots suivent les lignes, durées et chœur conservés', () {
      final incoming = SyncedLyrics([
        LyricLine(
          timestamp: const Duration(milliseconds: 4000),
          text: texts[0],
          words: const [
            LyricWord(
              start: Duration(milliseconds: 4000),
              duration: Duration(milliseconds: 500),
              text: 'Première',
            ),
            LyricWord(
              start: Duration(milliseconds: 4500),
              duration: Duration(milliseconds: 500),
              text: 'ligne',
              isBackground: true,
            ),
          ],
        ),
        const LyricLine(
          timestamp: Duration(milliseconds: 10000),
          text: 'Deuxième ligne du morceau',
        ),
        const LyricLine(
          timestamp: Duration(milliseconds: 16000),
          text: 'Troisième ligne du morceau',
        ),
      ]);
      final reference = lines([
        (6000, texts[0]),
        (12000, texts[1]),
        (18000, texts[2]),
      ]);
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isTrue);
      final line = result.lyrics.lines.first;
      expect(line.timestamp, const Duration(milliseconds: 6000));
      expect(line.words[0].start, const Duration(milliseconds: 6000));
      expect(line.words[0].duration, const Duration(milliseconds: 500));
      expect(line.words[1].start, const Duration(milliseconds: 6500));
      expect(line.words[1].isBackground, isTrue);
    });

    test('décalage négatif : plancher à zéro', () {
      final incoming = lines([
        (1000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
      ]);
      final reference = lines([
        (100, texts[0]),
        (8000, texts[1]),
        (14000, texts[2]),
      ]);
      // Écarts −900, −2000, −2000 : médiane −2000. La première ligne
      // tomberait à −1000 ms : plancher à 0.
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isTrue);
      expect(result.shiftMs, -2000);
      expect(result.lyrics.lines[0].timestamp, Duration.zero);
      expect(result.lyrics.lines[1].timestamp,
          const Duration(milliseconds: 8000));
    });

    test('décalage < 60 ms : inchangé', () {
      final incoming = lines([
        (4000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
      ]);
      final reference = lines([
        (4030, texts[0]),
        (10030, texts[1]),
        (16030, texts[2]),
      ]);
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isFalse);
      expect(result.shiftMs, 0);
      expect(identical(result.lyrics, incoming), isTrue);
    });

    test('moins de 3 lignes communes : inchangé', () {
      final incoming = lines([
        (4000, texts[0]),
        (10000, texts[1]),
        (16000, 'Une ligne unique à l’entrant'),
      ]);
      final reference = lines([
        (6000, texts[0]),
        (12000, texts[1]),
        (18000, 'Une ligne unique à la référence'),
      ]);
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isFalse);
      expect(identical(result.lyrics, incoming), isTrue);
    });

    test('écarts en désaccord : inchangé', () {
      final incoming = lines([
        (4000, texts[0]),
        (11000, texts[1]),
        (21000, texts[2]),
      ]);
      final reference = lines([
        (6000, texts[0]),
        (12000, texts[1]),
        (18000, texts[2]),
      ]);
      // Écarts 2000, 1000, −3000 : médiane 1000, seul 2 écarts sur 3
      // sont à ±1500 ms — il en faut 3.
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isFalse);
      expect(identical(result.lyrics, incoming), isTrue);
    });

    test('décalage > 20 s : inchangé', () {
      final incoming = lines([
        (4000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
      ]);
      final reference = lines([
        (29000, texts[0]),
        (35000, texts[1]),
        (41000, texts[2]),
      ]);
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isFalse);
    });

    test('lignes répétées : non appariées, mais décalées avec le reste', () {
      final incoming = lines([
        (4000, 'Refrain qui revient souvent'),
        (10000, texts[1]),
        (12000, 'Refrain qui revient souvent'),
        (16000, texts[2]),
        (20000, 'Refrain qui revient souvent'),
        (22000, texts[3]),
      ]);
      final reference = lines([
        (4000, 'Refrain qui revient souvent'),
        (12000, texts[1]),
        (12000, 'Refrain qui revient souvent'),
        (18000, texts[2]),
        (20000, 'Refrain qui revient souvent'),
        (24000, texts[3]),
      ]);
      // Sans le refrain, les écarts sont 2000, 2000, 2000 : le décalage
      // est 2000, et le refrain (non apparié) bouge avec le reste.
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isTrue);
      expect(result.shiftMs, 2000);
      expect(result.lyrics.lines[0].timestamp,
          const Duration(milliseconds: 6000));
    });

    test('accents et casse : appariés quand même', () {
      final incoming = lines([
        (4000, 'Café du matin tranquille'),
        (10000, 'Deuxième ligne du morceau'),
        (16000, 'Troisième ligne du morceau'),
      ]);
      final reference = lines([
        (6000, 'cafe du matin tranquille'),
        (12000, 'DEUXIÈME LIGNE DU MORCEAU'),
        (18000, 'Troisième ligne du morceau'),
      ]);
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isTrue);
      expect(result.shiftMs, 2000);
    });

    test('lignes courtes : non appariées', () {
      final incoming = lines([
        (4000, 'Oh'),
        (10000, texts[1]),
        (16000, texts[2]),
      ]);
      final reference = lines([
        (6000, 'Oh'),
        (12000, texts[1]),
        (18000, texts[2]),
      ]);
      // « Oh » fait 2 caractères de clé : seuls 2 écarts comptent,
      // il en faut 3.
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isFalse);
    });

    test('ligne de référence à 0 : non appariée', () {
      final incoming = lines([
        (5000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
        (22000, texts[3]),
      ]);
      final reference = lines([
        (0, texts[0]),
        (12000, texts[1]),
        (18000, texts[2]),
        (24000, texts[3]),
      ]);
      // La première ligne (à 0) ne compte pas ; les 3 autres donnent
      // un écart de 2000 ms.
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isTrue);
      expect(result.shiftMs, 2000);
    });

    test('référence vide : inchangé', () {
      final incoming = lines([
        (4000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
      ]);
      final result = alignLyrics(
        incoming: incoming,
        reference: SyncedLyrics.empty(),
      );
      expect(result.aligned, isFalse);
      expect(identical(result.lyrics, incoming), isTrue);
    });

    test('médiane haute sur un nombre pair d’écarts', () {
      final incoming = lines([
        (4000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
        (22000, texts[3]),
      ]);
      final reference = lines([
        (5000, texts[0]),
        (12000, texts[1]),
        (18000, texts[2]),
        (25000, texts[3]),
      ]);
      // Écarts 1000, 2000, 2000, 3000 : médiane = triés[2] = 2000.
      final result = alignLyrics(incoming: incoming, reference: reference);
      expect(result.aligned, isTrue);
      expect(result.shiftMs, 2000);
    });
  });

  group('isOtherRecordingSource', () {
    test('LyricsPlus et lrc.red : oui, LRCLIB : non', () {
      expect(isOtherRecordingSource('LyricsPlus'), isTrue);
      expect(isOtherRecordingSource('lrc.red'), isTrue);
      expect(isOtherRecordingSource('LRCLIB'), isFalse);
      expect(isOtherRecordingSource(''), isFalse);
    });
  });
}
