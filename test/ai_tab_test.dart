// The IA tab: the add button must wait for the stored settings, and an
// instruction typed but never unfocused must still be saved on close.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/automation_store.dart';
import 'package:musync/features/ai_assistant/providers/automation_provider.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';
import 'package:musync/features/settings/ui/ai_tab.dart';

class _MemoryStore extends AiSettingsStore {
  AiSettings settings;

  _MemoryStore(this.settings);

  @override
  Future<AiSettings> load() async => settings;

  @override
  Future<void> save(AiSettings next) async {
    settings = next;
  }
}

class _GatedStore extends AiSettingsStore {
  final gate = Completer<AiSettings>();

  @override
  Future<AiSettings> load() => gate.future;

  @override
  Future<void> save(AiSettings next) async {}
}

/// No automations on disk, and no disk to read: see the note in `main`.
class _EmptyAutomationStore extends AutomationStore {
  const _EmptyAutomationStore();

  @override
  Future<AutomationsDoc> load() async => const AutomationsDoc();
}

void main() {
  // AiTab also shows the automations section, whose real store reads
  // `path_provider`: with no plugin in a widget test that call never
  // resolves, `automationsProvider` stays loading and its spinner keeps
  // scheduling frames, so `pumpAndSettle` times out. The empty store
  // below answers at once, in pure Dart — no file, no log line (a
  // failing locator would log through DebugLog, whose 2 s flush timer
  // then fails the test teardown as still pending). The settings store
  // is overridden per test, as before.
  const noFsAutomationStore = _EmptyAutomationStore();

  testWidgets('the add button is disabled until the settings load', (
    tester,
  ) async {
    final store = _GatedStore();
    await tester.pumpWidget(
      MaterialApp(
        home: ProviderScope(
          overrides: [
            aiSettingsStoreProvider.overrideWithValue(store),
            automationStoreProvider.overrideWithValue(noFsAutomationStore),
          ],
          child: const AiTab(),
        ),
      ),
    );
    await tester.pump();

    // Still loading: the button must not fire `add` on an empty state,
    // which would overwrite the providers stored on disk.
    final fab = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton),
    );
    expect(fab.onPressed, isNull);

    store.gate.complete(const AiSettings());
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('closing the screen with the field focused still saves', (
    tester,
  ) async {
    final store = _MemoryStore(const AiSettings());
    final showTab = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        home: ProviderScope(
          overrides: [
            aiSettingsStoreProvider.overrideWithValue(store),
            automationStoreProvider.overrideWithValue(noFsAutomationStore),
          ],
          child: ValueListenableBuilder<bool>(
            valueListenable: showTab,
            builder: (_, show, _) =>
                show ? const AiTab() : const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open the instruction card and type, without ever leaving the field:
    // the Focus listener is removed before the detach unfocuses it, so the
    // usual focus-loss save never fires on this path.
    await tester.tap(find.text('Instruction donnée au modèle'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Nouvelle instruction');

    showTab.value = false;
    await tester.pump();
    await tester.pump();

    expect(store.settings.instruction, 'Nouvelle instruction');
  });
}
