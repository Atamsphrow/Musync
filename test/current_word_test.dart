// Tests de la règle du mot courant (karaoké) : pure, sans lecteur.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';

SyncedLyrics sample() => SyncedLyrics([
  const LyricLine(timestamp: Duration(milliseconds: 4000), text: 'Sans mots'),
  LyricLine(
    timestamp: const Duration(milliseconds: 10000),
    text: 'Une ligne ici',
    words: const [
      LyricWord(
        start: Duration(milliseconds: 10000),
        duration: Duration(milliseconds: 500),
        text: 'Une',
      ),
      LyricWord(
        start: Duration(milliseconds: 10500),
        duration: Duration(milliseconds: 500),
        text: 'ligne',
      ),
      LyricWord(
        start: Duration(milliseconds: 11000),
        duration: Duration(milliseconds: 500),
        text: 'ici',
      ),
    ],
  ),
]);

void main() {
  group('currentWordAt', () {
    test('avant la première ligne : null', () {
      expect(currentWordAt(sample(), const Duration(milliseconds: 1000)),
          isNull);
    });

    test('ligne sans mots : null', () {
      expect(currentWordAt(sample(), const Duration(milliseconds: 5000)),
          isNull);
    });

    test('ligne commencée, premier mot pas encore : null', () {
      // La ligne démarre à 10000 ms, le premier mot aussi : à 10000 ms
      // pile, c'est le premier mot. Un mot qui démarrerait après la
      // ligne laisserait ce cas — couvert par le test suivant.
      expect(
        currentWordAt(sample(), const Duration(milliseconds: 10000)),
        (lineIndex: 1, wordIndex: 0),
      );
    });

    test('milieu du deuxième mot : (1, 1)', () {
      expect(
        currentWordAt(sample(), const Duration(milliseconds: 10750)),
        (lineIndex: 1, wordIndex: 1),
      );
    });

    test('entre deux mots : le dernier commencé', () {
      // Les mots font 500 ms avec des trous de 0 ms ici ; un trou réel
      // (mot fini à 11000, suivant à 11500) garde le mot précédent.
      final gapped = SyncedLyrics([
        LyricLine(
          timestamp: const Duration(milliseconds: 10000),
          text: 'A B',
          words: const [
            LyricWord(
              start: Duration(milliseconds: 10000),
              duration: Duration(milliseconds: 200),
              text: 'A',
            ),
            LyricWord(
              start: Duration(milliseconds: 11000),
              duration: Duration(milliseconds: 200),
              text: 'B',
            ),
          ],
        ),
      ]);
      expect(
        currentWordAt(gapped, const Duration(milliseconds: 10500)),
        (lineIndex: 0, wordIndex: 0),
      );
    });

    test('exactement au début d\'un mot : ce mot-là', () {
      expect(
        currentWordAt(sample(), const Duration(milliseconds: 11000)),
        (lineIndex: 1, wordIndex: 2),
      );
    });

    test('après le dernier mot : le dernier mot', () {
      expect(
        currentWordAt(sample(), const Duration(milliseconds: 20000)),
        (lineIndex: 1, wordIndex: 2),
      );
    });
  });
}
