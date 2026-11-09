/// Correctifs du lot E (moyennes confirmées) :
/// - E9  : `describeSchedule` d'une action unique lit l'heure dans
///   `fireAtMillis`, pas dans les champs `hour`/`minute`.
/// - E10 : `alignStale` recalcule aussi les quotidiennes futures dont
///   l'heure ne correspond plus à `hour`/`minute`.
/// - E11 : échec de `save()` dans `_commit` → état restauré, pas de
///   `syncAlarms` (le natif ne doit pas armer un document absent du disque).
/// - E12 : `scheduleOnce` rejette un `at` passé.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/automation.dart';
import 'package:musync/features/ai_assistant/data/automation_store.dart';
import 'package:musync/features/ai_assistant/providers/automation_provider.dart';

void main() {
  group('E9 describeSchedule', () {
    test('unique : heure de fireAtMillis, pas des champs hour/minute', () {
      final at = DateTime(2026, 10, 9, 7, 0);
      final a = ScheduledAction(
        id: 'x',
        daily: false,
        fireAtMillis: at.millisecondsSinceEpoch,
        // Champs divergents (DST, changement de fuseau, resync partielle).
        hour: 9,
        minute: 30,
        toolName: 'play',
        label: 'Réveil',
      );
      expect(a.describeSchedule(), contains('9 oct'));
      expect(a.describeSchedule(), contains('07:00'));
      expect(a.describeSchedule(), isNot(contains('09:30')));
    });

    test('quotidienne : toujours hour/minute', () {
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
  });

  group('E10 alignStale', () {
    late _MemoryStore store;

    setUp(() {
      store = _MemoryStore();
    });

    Future<ProviderContainer> seeded(List<ScheduledAction> actions) async {
      store.doc = AutomationsDoc(actions: actions);
      final container = ProviderContainer(
        overrides: [automationStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container.read(automationsProvider.future);
      return container;
    }

    test('quotidienne future incohérente : recalculée', () async {
      final now = DateTime.now();
      // Occurrence voulue ~3 h devant nous (marge : aucun passage de
      // minute proche ne change le résultat).
      final hour = (now.hour + 3) % 24;
      const minute = 0;
      final expected = ScheduledAction.nextDailyFire(hour, minute, now);
      // fireAt futur lui aussi, mais à une autre heure murale.
      final incoherent = ScheduledAction(
        id: 'daily',
        daily: true,
        fireAtMillis: now.add(const Duration(hours: 2)).millisecondsSinceEpoch,
        hour: hour,
        minute: minute,
        toolName: 'play',
        label: 'daily',
      );
      expect(
        DateTime.fromMillisecondsSinceEpoch(incoherent.fireAtMillis).hour,
        isNot(hour),
        reason: 'la fixture doit être incohérente pour exercer le correctif',
      );
      final container = await seeded([incoherent]);

      await container.read(automationsProvider.notifier).alignStale();

      final doc = await container.read(automationsProvider.future);
      expect(doc.actions.single.fireAtMillis, expected);
    });

    test('quotidienne future cohérente : inchangée', () async {
      final now = DateTime.now();
      final hour = (now.hour + 3) % 24;
      const minute = 0;
      final fireAt = ScheduledAction.nextDailyFire(hour, minute, now);
      final container = await seeded([
        ScheduledAction(
          id: 'daily',
          daily: true,
          fireAtMillis: fireAt,
          hour: hour,
          minute: minute,
          toolName: 'play',
          label: 'daily',
        ),
      ]);

      await container.read(automationsProvider.notifier).alignStale();

      final doc = await container.read(automationsProvider.future);
      expect(doc.actions.single.fireAtMillis, fireAt);
    });
  });

  group('E11 _commit en échec de save()', () {
    test('état restauré, rien persisté', () async {
      final keep = ScheduledAction(
        id: 'keep',
        daily: true,
        fireAtMillis: ScheduledAction.nextDailyFire(7, 0, DateTime.now()),
        hour: 7,
        minute: 0,
        toolName: 'play',
        label: 'keep',
      );
      final store = _FailingSaveStore(AutomationsDoc(actions: [keep]));
      final container = ProviderContainer(
        overrides: [automationStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container.read(automationsProvider.future);

      await container.read(automationsProvider.notifier).scheduleDaily(
            hour: 22,
            minute: 0,
            tool: 'play',
            label: 'new',
          );

      // L'état affiché est l'ancien : l'UI ne montre pas une
      // automatisation qui n'existe pas sur disque.
      final doc = await container.read(automationsProvider.future);
      expect(doc.actions.map((a) => a.id), ['keep']);
      expect(store.doc.actions.map((a) => a.id), ['keep']);
    });
  });

  group('E12 scheduleOnce', () {
    test('un at passé est rejeté, rien persisté', () async {
      final store = _MemoryStore();
      final container = ProviderContainer(
        overrides: [automationStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container.read(automationsProvider.future);
      final notifier = container.read(automationsProvider.notifier);

      await expectLater(
        notifier.scheduleOnce(
          at: DateTime.now().subtract(const Duration(minutes: 1)),
          tool: 'play',
          label: 'past',
        ),
        throwsArgumentError,
      );

      final doc = await container.read(automationsProvider.future);
      expect(doc.actions, isEmpty);
      expect(store.doc.actions, isEmpty);
    });

    test('un at futur est accepté', () async {
      final store = _MemoryStore();
      final container = ProviderContainer(
        overrides: [automationStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container.read(automationsProvider.future);
      final notifier = container.read(automationsProvider.notifier);

      final action = await notifier.scheduleOnce(
        at: DateTime.now().add(const Duration(hours: 1)),
        tool: 'play',
        label: 'future',
      );

      expect(action.label, 'future');
      expect(store.doc.actions.map((a) => a.id), [action.id]);
    });
  });
}

/// Store en mémoire : `load` rend le document, `save` le remplace.
class _MemoryStore extends AutomationStore {
  AutomationsDoc doc;

  _MemoryStore([this.doc = const AutomationsDoc()]);

  @override
  Future<AutomationsDoc> load() async => doc;

  @override
  Future<void> save(AutomationsDoc next) async {
    doc = next;
  }
}

/// Store dont la sauvegarde échoue toujours (disque plein, permissions…).
class _FailingSaveStore extends _MemoryStore {
  _FailingSaveStore(super.doc);

  @override
  Future<void> save(AutomationsDoc next) async {
    throw const FileSystemException('disque plein (test)');
  }
}
