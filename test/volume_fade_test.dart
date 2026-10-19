// La courbe du fondu de réveil : quadratique, bornée, monotone.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/player/data/volume_fade.dart';

void main() {
  group('VolumeFade.volumeAt', () {
    const duration = Duration(seconds: 90);

    test('démarre à 5 % du volume', () {
      expect(
        VolumeFade.volumeAt(Duration.zero, duration),
        VolumeFade.startVolume,
      );
    });

    test('atteint le volume cible à la fin', () {
      expect(VolumeFade.volumeAt(duration, duration), 1.0);
      expect(
        VolumeFade.volumeAt(duration * 2, duration),
        1.0,
        reason: 'ne dépasse jamais 1.0',
      );
    });

    test('est monotone croissante', () {
      var previous = 0.0;
      for (var s = 0; s <= 90; s += 5) {
        final v = VolumeFade.volumeAt(Duration(seconds: s), duration);
        expect(v, greaterThanOrEqualTo(previous));
        previous = v;
      }
    });

    test('monte moins vite qu\'un fondu linéaire au début', () {
      // Quadratique : à mi-parcours on est sous les 50 % — c'est ce qui
      // rend le réveil progressif au lieu de "rien puis tout d'un coup".
      final mid = VolumeFade.volumeAt(
        const Duration(seconds: 45),
        duration,
      );
      expect(mid, lessThan(0.5));
      expect(mid, greaterThan(VolumeFade.startVolume));
    });

    test('durée nulle ou négative = volume direct', () {
      expect(VolumeFade.volumeAt(Duration.zero, Duration.zero), 1.0);
    });

    test('temps négatif = volume de départ', () {
      expect(
        VolumeFade.volumeAt(const Duration(seconds: -5), duration),
        VolumeFade.startVolume,
      );
    });
  });
}
