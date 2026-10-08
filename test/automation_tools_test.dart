/// Tests des outils d'automatisation : validation des arguments, refus des
/// outils à confirmation, annulation par nom.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/ai_tool_registry.dart';
import 'package:musync/features/ai_assistant/data/automation_store.dart';
import 'package:musync/features/ai_assistant/data/tools/automation_tools.dart';
import 'package:musync/features/ai_assistant/providers/automation_provider.dart';

AiToolContext _ctx(ProviderContainer container) {
  final ref = container.read(_refProbe);
  final registry = buildAiToolRegistry();
  return AiToolContext(
    ref: ref,
    runTool: (_, _) async => AiToolResult.fail('non'),
    hasTool: registry.contains,
    requiresConfirmation: (name) =>
        registry[name]?.requiresConfirmation ?? true,
  );
}

final _refProbe = Provider<Ref>((ref) => ref);

ProviderContainer _container() {
  final dir = Directory.systemTemp.createTempSync('musync_auto_tools');
  addTearDown(() => dir.deleteSync(recursive: true));
  final container = ProviderContainer(
    overrides: [
      automationStoreProvider.overrideWithValue(
        // ignore: prefer_const_constructors — fileLocator n'est pas const
        AutomationStore(
          fileLocator: () async => File('${dir.path}/automations.json'),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _execute(
  ProviderContainer container,
  AiTool tool,
  Map<String, Object?> args,
) async {
  // Comme le contrôleur : AiToolArgError → échec propre.
  try {
    final result = await tool.execute(_ctx(container), args);
    expect(result.ok, isTrue, reason: result.message);
  } on AiToolArgError catch (e) {
    fail('erreur inattendue : ${e.message}');
  }
}

void main() {
  group('registre', () {
    test('les 6 outils sont enregistrés, aucun à confirmation', () {
      final registry = buildAiToolRegistry();
      for (final name in [
        'schedule_once',
        'schedule_daily',
        'list_scheduled_actions',
        'cancel_scheduled_action',
        'set_headphone_trigger',
        'clear_headphone_trigger',
      ]) {
        expect(registry.contains(name), isTrue, reason: name);
        expect(registry[name]!.requiresConfirmation, isFalse, reason: name);
      }
    });
  });

  group('schedule_daily', () {
    test('heure invalide refusée', () async {
      final container = _container();
      await expectLater(
        () => const ScheduleDailyTool().execute(
          _ctx(container),
          {'hour': 25, 'minute': 0, 'tool': 'pause'},
        ),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('outil à confirmation refusé', () async {
      final container = _container();
      await expectLater(
        () => const ScheduleDailyTool().execute(
          _ctx(container),
          {'hour': 22, 'minute': 0, 'tool': 'delete_file'},
        ),
        throwsA(
          isA<AiToolArgError>().having(
            (e) => e.message,
            'message',
            contains('confirmation'),
          ),
        ),
      );
    });

    test('outil inconnu refusé', () async {
      final container = _container();
      await expectLater(
        () => const ScheduleDailyTool().execute(
          _ctx(container),
          {'hour': 22, 'minute': 0, 'tool': 'lance_des_missiles'},
        ),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('planifie et liste', () async {
      final container = _container();
      await _execute(container, const ScheduleDailyTool(), {
        'hour': 22,
        'minute': 0,
        'tool': 'sleep_timer',
        'args': {'minutes': 30},
        'label': 'Minuteur 22h',
      });
      final actions =
          (await container.read(automationsProvider.future)).actions;
      expect(actions.length, 1);
      expect(actions.single.daily, isTrue);
      expect(actions.single.label, 'Minuteur 22h');

      final listed = await const ListScheduledActionsTool()
          .execute(_ctx(container), {});
      expect(listed.message, contains('Minuteur 22h'));
      expect(listed.message, contains('Tous les jours à 22:00'));
    });
  });

  group('schedule_once', () {
    test('date passée refusée', () async {
      final container = _container();
      await expectLater(
        () => const ScheduleOnceTool().execute(
          _ctx(container),
          {'datetime': '2020-01-01T07:00', 'tool': 'pause'},
        ),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('date invalide refusée', () async {
      final container = _container();
      await expectLater(
        () => const ScheduleOnceTool().execute(
          _ctx(container),
          {'datetime': 'demain', 'tool': 'pause'},
        ),
        throwsA(isA<AiToolArgError>()),
      );
    });
  });

  group('cancel_scheduled_action', () {
    test('annule par morceau de nom', () async {
      final container = _container();
      await _execute(container, const ScheduleDailyTool(), {
        'hour': 22,
        'minute': 0,
        'tool': 'pause',
        'label': 'Minuteur 22h',
      });
      final result = await const CancelScheduledActionTool().execute(
        _ctx(container),
        {'cible': '22h'},
      );
      expect(result.ok, isTrue);
      expect(
        (await container.read(automationsProvider.future)).actions,
        isEmpty,
      );
    });

    test('cible inconnue : échec clair', () async {
      final container = _container();
      await expectLater(
        () => const CancelScheduledActionTool().execute(
          _ctx(container),
          {'cible': 'zzz'},
        ),
        throwsA(isA<AiToolArgError>()),
      );
    });
  });

  group('déclencheur écouteurs', () {
    test('définit puis supprime', () async {
      final container = _container();
      await _execute(container, const SetHeadphoneTriggerTool(), {
        'tool': 'play',
        'args': {'query': 'Nuit'},
        'label': 'File Nuit',
      });
      expect(
        (await container.read(automationsProvider.future))
            .headphoneTrigger!
            .label,
        'File Nuit',
      );
      await _execute(container, const ClearHeadphoneTriggerTool(), {});
      expect(
        (await container.read(automationsProvider.future)).headphoneTrigger,
        isNull,
      );
    });

    test('outil à confirmation refusé', () async {
      final container = _container();
      await expectLater(
        () => const SetHeadphoneTriggerTool().execute(
          _ctx(container),
          {'tool': 'edit_tags'},
        ),
        throwsA(isA<AiToolArgError>()),
      );
    });
  });
}
