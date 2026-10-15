import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/schedule_router.dart';

void main() {
  // Jeudi 15/10/2026, 03:30.
  final ref = DateTime(2026, 10, 15, 3, 30);

  String? toolOf(String? json) {
    if (json == null) return null;
    return (jsonDecode(json) as Map)['tool'] as String?;
  }

  String? datetimeOf(String? json) {
    if (json == null) return null;
    return ((jsonDecode(json) as Map)['args'] as Map)['datetime'] as String?;
  }

  group('routeScheduledPlay', () {
    test('lance la musique à 4h43 → schedule_once le jour même', () {
      final r = routeScheduledPlay('lance la musique à 4h43', now: ref);
      expect(toolOf(r), 'schedule_once');
      expect(datetimeOf(r), '2026-10-15T04:43');
    });

    test('heure déjà passée → lendemain', () {
      final r = routeScheduledPlay(
        'lance la musique à 4h43',
        now: DateTime(2026, 10, 15, 5, 0),
      );
      expect(toolOf(r), 'schedule_once');
      expect(datetimeOf(r), '2026-10-16T04:43');
    });

    test('joue de la musique à 04:43', () {
      final r = routeScheduledPlay('joue de la musique à 04:43', now: ref);
      expect(toolOf(r), 'schedule_once');
      expect(datetimeOf(r), '2026-10-15T04:43');
    });

    test('démarre la musique demain à 7h', () {
      final r = routeScheduledPlay('démarre la musique demain à 7h', now: ref);
      expect(toolOf(r), 'schedule_once');
      expect(datetimeOf(r), '2026-10-16T07:00');
    });

    test('annule le minuteur de 22h → jamais intercepté', () {
      expect(
        routeScheduledPlay('annule le minuteur de 22h', now: ref),
        isNull,
      );
    });

    test('supprime l\'alarme de 7h05 → jamais intercepté', () {
      expect(
        routeScheduledPlay("supprime l'alarme de 7h05", now: ref),
        isNull,
      );
    });

    test('stop la musique à 22h → jamais intercepté', () {
      expect(
        routeScheduledPlay('stop la musique à 22h', now: ref),
        isNull,
      );
    });

    test('joue du Niska → modèle (pas d\'heure)', () {
      expect(routeScheduledPlay('joue du Niska', now: ref), isNull);
    });

    test('joue du Niska à 22h → modèle (contenu précis)', () {
      expect(routeScheduledPlay('joue du Niska à 22h', now: ref), isNull);
    });

    test('tous les jours à 22h → modèle (schedule_daily)', () {
      expect(
        routeScheduledPlay('lance la musique tous les jours à 22h', now: ref),
        isNull,
      );
    });

    test('dans 10 minutes → modèle (relatif)', () {
      expect(
        routeScheduledPlay('lance la musique dans 10 minutes', now: ref),
        isNull,
      );
    });

    test('heure invalide → modèle', () {
      expect(
        routeScheduledPlay('lance la musique à 25h', now: ref),
        isNull,
      );
    });

    test('le plan généré est un schedule_once valide', () {
      final r = routeScheduledPlay('lance la musique à 4h43', now: ref);
      final map = jsonDecode(r!) as Map;
      expect(map['tool'], 'schedule_once');
      final args = map['args'] as Map;
      expect(args['tool'], 'play');
      expect(args['datetime'], '2026-10-15T04:43');
      expect((args['label'] as String).isNotEmpty, isTrue);
    });
  });
}
