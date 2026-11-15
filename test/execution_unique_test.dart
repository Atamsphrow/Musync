import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/providers/background_lyrics_provider.dart';

void main() {
  group('ExecutionUnique', () {
    test('une clé déjà en cours rejoint l\'exécution au lieu d\'en lancer '
        'une seconde', () async {
      final unique = ExecutionUnique<String>();
      final gate = Completer<void>();
      var lancements = 0;

      Future<void> tache() async {
        lancements++;
        await gate.future;
      }

      final premier = unique.lancer('a.mp3', tache);
      final second = unique.lancer('a.mp3', tache);

      expect(lancements, 1);
      expect(identical(premier, second), isTrue);
      expect(unique.enCours('a.mp3'), isNotNull);

      gate.complete();
      await Future.wait([premier, second]);
      expect(lancements, 1);
    });

    test('la clé est enregistrée avant le premier await de la tâche',
        () async {
      final unique = ExecutionUnique<String>();
      final gate = Completer<void>();

      final f = unique.lancer('a.mp3', () async {
        await gate.future;
      });
      // Aucun tour de boucle d'événements écoulé : déjà visible.
      expect(unique.enCours('a.mp3'), isNotNull);

      gate.complete();
      await f;
    });

    test('des clés différentes tournent en parallèle', () async {
      final unique = ExecutionUnique<String>();
      final porteA = Completer<void>();
      final porteB = Completer<void>();
      final demarres = <String>[];

      final a = unique.lancer('a.mp3', () async {
        demarres.add('a');
        await porteA.future;
      });
      final b = unique.lancer('b.mp3', () async {
        demarres.add('b');
        await porteB.future;
      });

      // Les deux ont démarré sans que la première soit terminée.
      expect(demarres, ['a', 'b']);

      porteA.complete();
      porteB.complete();
      await Future.wait([a, b]);
    });

    test('la clé est libérée à la fin, et une nouvelle exécution est '
        'possible ensuite', () async {
      final unique = ExecutionUnique<String>();
      var lancements = 0;

      await unique.lancer('a.mp3', () async {
        lancements++;
      });
      expect(unique.enCours('a.mp3'), isNull);

      await unique.lancer('a.mp3', () async {
        lancements++;
      });
      expect(lancements, 2);
    });

    test('la clé est libérée même si la tâche lève', () async {
      final unique = ExecutionUnique<String>();

      await expectLater(
        unique.lancer('a.mp3', () async {
          throw StateError('boum');
        }),
        throwsStateError,
      );
      expect(unique.enCours('a.mp3'), isNull);
    });
  });
}
