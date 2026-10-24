/// alignStale: at launch, past automations are realigned WITHOUT
/// running them — a daily moves to its next occurrence, a missed
/// one-shot is dropped, and the alarm that just launched the app is
/// spared. Without this, re-syncing a stale hour to the native
/// scheduler fires it immediately (the 07:00 wake-up at 09:30).
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/automation.dart';
import 'package:musync/features/ai_assistant/data/automation_store.dart';
import 'package:musync/features/ai_assistant/providers/automation_provider.dart';

void main() {
  late Directory dir;
  late AutomationStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('musync_align_stale');
    store = AutomationStore(
      fileLocator: () async => File('${dir.path}/automations.json'),
    );
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ScheduledAction action(
    String id, {
    required bool daily,
    required DateTime fireAt,
  }) {
    return ScheduledAction(
      id: id,
      daily: daily,
      fireAtMillis: fireAt.millisecondsSinceEpoch,
      hour: fireAt.hour,
      minute: fireAt.minute,
      toolName: 'play',
      label: id,
    );
  }

  Future<ProviderContainer> seeded(List<ScheduledAction> actions) async {
    await store.save(AutomationsDoc(actions: actions));
    final container = ProviderContainer(
      overrides: [automationStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    await container.read(automationsProvider.future);
    return container;
  }

  test('a stale daily moves to its next occurrence, unrun', () async {
    final now = DateTime.now();
    // Yesterday at this time of day: unambiguously past, and its next
    // occurrence is unambiguously within the coming day.
    final stale = now.subtract(const Duration(days: 1));
    final container = await seeded([
      action('daily', daily: true, fireAt: stale),
    ]);

    await container.read(automationsProvider.notifier).alignStale();

    final doc = await container.read(automationsProvider.future);
    expect(doc.actions, hasLength(1));
    final fireAt = DateTime.fromMillisecondsSinceEpoch(
      doc.actions.single.fireAtMillis,
    );
    expect(fireAt.isAfter(now), isTrue);
    expect(fireAt.difference(now) <= const Duration(days: 1), isTrue);
    expect(fireAt.hour, stale.hour);
    expect(fireAt.minute, stale.minute);
  });

  test('a stale one-shot is dropped, a future one is kept', () async {
    final now = DateTime.now();
    final container = await seeded([
      action('missed', daily: false, fireAt: now.subtract(const Duration(hours: 2))),
      action('later', daily: false, fireAt: now.add(const Duration(hours: 2))),
    ]);

    await container.read(automationsProvider.notifier).alignStale();

    final doc = await container.read(automationsProvider.future);
    expect(doc.actions.map((a) => a.id), ['later']);
  });

  test('the alarm that launched the app is spared, even stale', () async {
    final now = DateTime.now();
    final container = await seeded([
      action('fired', daily: false, fireAt: now.subtract(const Duration(minutes: 1))),
      action('missed', daily: false, fireAt: now.subtract(const Duration(hours: 3))),
    ]);

    await container
        .read(automationsProvider.notifier)
        .alignStale(except: 'fired');

    final doc = await container.read(automationsProvider.future);
    expect(doc.actions.map((a) => a.id), ['fired']);
  });
}
