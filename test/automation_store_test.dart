/// Tests des automatisations phase 2 : modèles, store, calculs d'échéance.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/automation.dart';
import 'package:musync/features/ai_assistant/data/automation_store.dart';

/// Un fichier stable : le locator est rappelé à chaque lecture/écriture,
/// il doit toujours désigner le même fichier.
AutomationStore _tempStore() {
  final dir = Directory.systemTemp.createTempSync('musync_auto_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/automations.json');
  return AutomationStore(fileLocator: () async => file);
}

void main() {
  group('ScheduledAction.nextDailyFire', () {
    test('plus tard aujourd’hui → aujourd’hui', () {
      final from = DateTime(2026, 10, 8, 21, 0);
      final fire = ScheduledAction.nextDailyFire(22, 0, from);
      final at = DateTime.fromMillisecondsSinceEpoch(fire);
      expect((at.day, at.hour, at.minute), (8, 22, 0));
    });

    test('heure passée → demain', () {
      final from = DateTime(2026, 10, 8, 23, 0);
      final fire = ScheduledAction.nextDailyFire(22, 0, from);
      final at = DateTime.fromMillisecondsSinceEpoch(fire);
      expect((at.day, at.hour, at.minute), (9, 22, 0));
    });

    test('exactement maintenant → demain (strictement après)', () {
      final from = DateTime(2026, 10, 8, 22, 0);
      final fire = ScheduledAction.nextDailyFire(22, 0, from);
      final at = DateTime.fromMillisecondsSinceEpoch(fire);
      expect(at.day, 9);
    });
  });

  group('describeSchedule', () {
    test('quotidienne', () {
      const a = ScheduledAction(
        id: 'x',
        daily: true,
        fireAtMillis: 0,
        hour: 22,
        minute: 5,
        toolName: 'sleep_timer',
        label: 'Minuteur',
      );
      expect(a.describeSchedule(), 'Tous les jours à 22:05');
    });

    test('unique', () {
      final at = DateTime(2026, 10, 9, 7, 0);
      final a = ScheduledAction(
        id: 'x',
        daily: false,
        fireAtMillis: at.millisecondsSinceEpoch,
        hour: 7,
        minute: 0,
        toolName: 'play',
        label: 'Réveil',
      );
      expect(a.describeSchedule(), contains('9 oct'));
      expect(a.describeSchedule(), contains('07:00'));
    });
  });

  group('JSON', () {
    test('aller-retour action + déclencheur', () {
      const doc = AutomationsDoc(
        actions: [
          ScheduledAction(
            id: 's1',
            daily: true,
            fireAtMillis: 123,
            hour: 22,
            minute: 0,
            toolName: 'sleep_timer',
            args: {'minutes': 30},
            label: 'Minuteur 22h',
          ),
        ],
        headphoneTrigger: HeadphoneTrigger(
          toolName: 'play',
          args: {'query': 'Nuit'},
          label: 'File Nuit',
        ),
      );
      final back = AutomationsDoc.fromJson(doc.toJson());
      expect(back.actions.length, 1);
      expect(back.actions.single.label, 'Minuteur 22h');
      expect(back.actions.single.args['minutes'], 30);
      expect(back.headphoneTrigger!.label, 'File Nuit');
    });

    test('JSON illisible → ignoré, pas d’exception', () {
      expect(AutomationsDoc.fromJson('n’importe quoi').actions, isEmpty);
      expect(ScheduledAction.fromJson({'id': 'x'}), isNull);
    });
  });

  group('AutomationStore', () {
    test('save/load aller-retour', () async {
      final store = _tempStore();
      const doc = AutomationsDoc(
        actions: [
          ScheduledAction(
            id: 's1',
            daily: false,
            fireAtMillis: 999,
            hour: 7,
            minute: 0,
            toolName: 'play',
            label: 'Réveil',
          ),
        ],
      );
      await store.save(doc);
      final loaded = await store.load();
      expect(loaded.actions.single.id, 's1');
      expect(loaded.headphoneTrigger, isNull);
    });

    test('pas de fichier → doc vide', () async {
      final store = _tempStore();
      final loaded = await store.load();
      expect(loaded.actions, isEmpty);
    });
  });
}
