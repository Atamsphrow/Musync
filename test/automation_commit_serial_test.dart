/// `_commit` sérialisé (finding haute B3) : deux mutations concurrentes
/// ne doivent ni perdre une action, ni laisser le store — et donc le
/// miroir natif via `syncAlarms` — avec le document le plus ancien.
///
/// Sous `flutter test`, `Platform.isAndroid` est faux : `syncAlarms` est un
/// no-op. Le store factice reproduit le même mécanisme côté sauvegarde :
/// le 1er `save` (1 action) est lent, le 2e (2 actions) rapide. Sans
/// sérialisation, le 1er termine après le 2e et écrase le store avec le
/// document périmé (une seule action) ; avec, les sauvegardes s'exécutent
/// dans l'ordre et le document final contient les deux actions.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/automation_store.dart';
import 'package:musync/features/ai_assistant/providers/automation_provider.dart';

void main() {
  group('AutomationsNotifier._commit sérialisé', () {
    test('deux scheduleDaily concurrents : aucune action perdue, '
        'sauvegardes dans l’ordre', () async {
      final store = _DelayedStore();
      final container = ProviderContainer(
        overrides: [automationStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      container.listen(automationsProvider, (_, _) {});

      await container.read(automationsProvider.future);
      final notifier = container.read(automationsProvider.notifier);

      final first = notifier.scheduleDaily(
        hour: 22,
        minute: 0,
        tool: 'play',
        label: 'A',
      );
      final second = notifier.scheduleDaily(
        hour: 7,
        minute: 30,
        tool: 'play',
        label: 'B',
      );
      await Future.wait([first, second]);

      expect(store.doc.actions.map((a) => a.label), ['A', 'B']);
      expect(
        store.savedDocs.map((d) => d.actions.length),
        [1, 2],
        reason: 'les sauvegardes doivent s’exécuter dans l’ordre, '
            'sinon la lente écrase la récente',
      );
      expect(
        container.read(automationsProvider).valueOrNull?.actions.length,
        2,
      );
    });

    test('advanceAfterFire sur une unique ne s’interbloque pas '
        '(cancel imbriqué)', () async {
      final store = _DelayedStore();
      final container = ProviderContainer(
        overrides: [automationStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      container.listen(automationsProvider, (_, _) {});

      await container.read(automationsProvider.future);
      final notifier = container.read(automationsProvider.notifier);
      final action = await notifier.scheduleOnce(
        at: DateTime.now().add(const Duration(hours: 1)),
        tool: 'play',
        label: 'once',
      );

      // Timeout : un interblocage _serialized → cancel ferait échouer.
      await notifier
          .advanceAfterFire(action.id)
          .timeout(const Duration(seconds: 5));

      expect(store.doc.actions, isEmpty);
    });
  });
}

/// Store factice : `save` lent quand le document n'a qu'une action,
/// rapide ensuite — l'inversion d'ordre d'achèvement sans sérialisation.
class _DelayedStore extends AutomationStore {
  AutomationsDoc doc = const AutomationsDoc();
  final savedDocs = <AutomationsDoc>[];

  @override
  Future<AutomationsDoc> load() async => doc;

  @override
  Future<void> save(AutomationsDoc next) async {
    final delay = next.actions.length <= 1
        ? const Duration(milliseconds: 60)
        : const Duration(milliseconds: 5);
    await Future.delayed(delay);
    doc = next;
    savedDocs.add(next);
  }
}
