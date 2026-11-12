// Tests de l'horloge des paroles : jamais de retour en arrière sauf seek.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/player/data/lyric_clock.dart';

void main() {
  group('LyricClock', () {
    test('premier tick : la position brute', () {
      expect(LyricClock().tick(const Duration(seconds: 10)),
          const Duration(seconds: 10));
    });

    test('avance suivie', () {
      final clock = LyricClock();
      clock.tick(const Duration(milliseconds: 10000));
      expect(clock.tick(const Duration(milliseconds: 10016)),
          const Duration(milliseconds: 10016));
    });

    test('petit recul absorbé, puis rattrapé', () {
      final clock = LyricClock();
      clock.tick(const Duration(milliseconds: 10000));
      // L'ancre se met à jour 5 ms en arrière : la ligne ne bouge pas.
      expect(clock.tick(const Duration(milliseconds: 9995)),
          const Duration(milliseconds: 10000));
      expect(clock.tick(const Duration(milliseconds: 9998)),
          const Duration(milliseconds: 10000));
      // La lecture brute repasse devant : on la suit de nouveau.
      expect(clock.tick(const Duration(milliseconds: 10001)),
          const Duration(milliseconds: 10001));
    });

    test('recul de 800 ms pile : absorbé', () {
      final clock = LyricClock();
      clock.tick(const Duration(milliseconds: 10000));
      expect(clock.tick(const Duration(milliseconds: 9200)),
          const Duration(milliseconds: 10000));
    });

    test('recul de 801 ms : suivi (seek)', () {
      final clock = LyricClock();
      clock.tick(const Duration(milliseconds: 10000));
      expect(clock.tick(const Duration(milliseconds: 9199)),
          const Duration(milliseconds: 9199));
    });

    test('boucle : retour à zéro suivi', () {
      final clock = LyricClock();
      clock.tick(const Duration(milliseconds: 170000));
      expect(clock.tick(Duration.zero), Duration.zero);
      expect(clock.tick(const Duration(milliseconds: 16)),
          const Duration(milliseconds: 16));
    });

    test('pause : position figée répétée', () {
      final clock = LyricClock();
      clock.tick(const Duration(milliseconds: 5000));
      expect(clock.tick(const Duration(milliseconds: 5000)),
          const Duration(milliseconds: 5000));
      expect(clock.tick(const Duration(milliseconds: 5000)),
          const Duration(milliseconds: 5000));
    });

    test('saut avant suivi immédiatement', () {
      final clock = LyricClock();
      clock.tick(const Duration(milliseconds: 10000));
      expect(clock.tick(const Duration(milliseconds: 60000)),
          const Duration(milliseconds: 60000));
    });
  });
}
