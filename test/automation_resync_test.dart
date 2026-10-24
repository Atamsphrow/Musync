/// Réarmement des alarmes exactes après autorisation hors de l'app.
///
/// Sous `flutter test`, `Platform.isAndroid` est faux : `syncAlarms` est un
/// no-op qui rend true. On vérifie la logique du notifier : store non
/// réécrit, `exactAlarmGrantedProvider` repassé à true.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/automation_store.dart';
import 'package:musync/features/ai_assistant/providers/automation_provider.dart';

void main() {
  group('AutomationsNotifier.resync', () {
    test('repasse exactAlarmGrantedProvider à true sans toucher au store',
        () async {
      final store = _MemoryStore();
      final container = ProviderContainer(
        overrides: [
          automationStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      // Garde le provider vivant même s'il est autoDispose.
      container.listen(automationsProvider, (_, _) {});

      await container.read(automationsProvider.future);
      final before = container.read(automationsProvider).valueOrNull;
      final savesBefore = store.saves;
      container.read(exactAlarmGrantedProvider.notifier).state = false;

      await container.read(automationsProvider.notifier).resync();

      expect(container.read(automationsProvider).valueOrNull, before);
      expect(store.saves, savesBefore);
      expect(container.read(exactAlarmGrantedProvider), true);
    });
  });
}

/// Store factice en mémoire : `save` compte les écritures.
class _MemoryStore extends AutomationStore {
  int saves = 0;
  AutomationsDoc doc = const AutomationsDoc();

  @override
  Future<AutomationsDoc> load() async => doc;

  @override
  Future<void> save(AutomationsDoc next) async {
    saves++;
    doc = next;
  }
}
