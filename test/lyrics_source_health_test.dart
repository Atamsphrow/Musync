// Tests de la santé des sources : disjoncteur et mémo « pas de paroles ».
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/lyrics_source_health.dart';

void main() {
  late DateTime now;
  late LyricsSourceHealth health;

  setUp(() {
    now = DateTime(2026, 11, 12, 11, 0);
    health = LyricsSourceHealth(now: () => now);
  });

  const track = 'titre|artiste';

  group('disjoncteur', () {
    test('frais : rien n’est mis de côté', () {
      expect(health.isSetAside('LRCLIB'), isFalse);
      expect(health.setAsideRemaining('LRCLIB'), isNull);
    });

    test('2 échecs : toujours demandé ; 3e : mis de côté 10 min', () {
      health.failed('LRCLIB');
      health.failed('LRCLIB');
      expect(health.isSetAside('LRCLIB'), isFalse);
      health.failed('LRCLIB');
      expect(health.isSetAside('LRCLIB'), isTrue);
      final remaining = health.setAsideRemaining('LRCLIB')!;
      expect(remaining.inMinutes, 10);
    });

    test('une réponse remet le compteur à zéro', () {
      health.failed('LRCLIB');
      health.failed('LRCLIB');
      health.answered('LRCLIB');
      health.failed('LRCLIB');
      health.failed('LRCLIB');
      expect(health.isSetAside('LRCLIB'), isFalse);
      health.failed('LRCLIB');
      expect(health.isSetAside('LRCLIB'), isTrue);
    });

    test('la mise de côté expire après 10 min', () {
      health.failed('LRCLIB');
      health.failed('LRCLIB');
      health.failed('LRCLIB');
      now = now.add(const Duration(minutes: 9, seconds: 59));
      expect(health.isSetAside('LRCLIB'), isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(health.isSetAside('LRCLIB'), isFalse);
      expect(health.setAsideRemaining('LRCLIB'), isNull);
    });

    test('les sources sont indépendantes', () {
      health.failed('LRCLIB');
      health.failed('LRCLIB');
      health.failed('LRCLIB');
      expect(health.isSetAside('LyricsPlus'), isFalse);
    });
  });

  group('mémo « pas de paroles »', () {
    test('noté puis lu pendant 5 min, expiré après', () {
      expect(health.isMissing(track, 'LRCLIB'), isFalse);
      health.noteMissing(track, 'LRCLIB');
      expect(health.isMissing(track, 'LRCLIB'), isTrue);
      now = now.add(const Duration(minutes: 4, seconds: 59));
      expect(health.isMissing(track, 'LRCLIB'), isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(health.isMissing(track, 'LRCLIB'), isFalse);
    });

    test('la clé plie la requête : « Café » = « cafe »', () {
      final key = lyricsHealthTrackKey('Café du Matin', 'Artiste');
      health.noteMissing(key, 'LRCLIB');
      expect(
        health.isMissing(
          lyricsHealthTrackKey('cafe du matin', 'artiste'),
          'LRCLIB',
        ),
        isTrue,
      );
      expect(
        health.isMissing(
          lyricsHealthTrackKey('autre titre', 'artiste'),
          'LRCLIB',
        ),
        isFalse,
      );
    });

    test('forgetTrack efface le morceau, pas les autres', () {
      health.noteMissing(track, 'LRCLIB');
      health.noteMissing('autre|artiste', 'LRCLIB');
      health.forgetTrack(track);
      expect(health.isMissing(track, 'LRCLIB'), isFalse);
      expect(health.isMissing('autre|artiste', 'LRCLIB'), isTrue);
    });

    test('le plafond évince les entrées expirées d’abord', () {
      for (var i = 0; i < 500; i++) {
        health.noteMissing('titre$i|artiste', 'LRCLIB');
      }
      now = now.add(const Duration(minutes: 6));
      health.noteMissing('nouveau|artiste', 'LRCLIB');
      expect(health.isMissing('titre0|artiste', 'LRCLIB'), isFalse);
      expect(health.isMissing('nouveau|artiste', 'LRCLIB'), isTrue);
    });
  });
}
