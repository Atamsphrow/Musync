/// Exécute les automatisations : alarmes qui sonnent, écouteurs branchés.
///
/// Branché au démarrage dans `_MusyncAppState` : resynchronise les alarmes
/// natives (Dart = source de vérité), vide l'action qui a ouvert l'app, et
/// installe le handler des événements natifs.
///
/// Les résultats vont au Journal (`DebugLog`) : quand une alarme ouvre l'app
/// à 7h, il n'y a pas forcément d'écran pour un snackbar — l'action elle-même
/// (lecture, minuteur…) est l'effet visible.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/ai_assistant/data/assistant_controller.dart';
import 'package:musync/features/ai_assistant/data/scheduler_bridge.dart';
import 'package:musync/features/ai_assistant/providers/automation_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';

final automationRunnerProvider = Provider<AutomationRunner>(
  (ref) => AutomationRunner(ref),
);

class AutomationRunner {
  final Ref _ref;

  /// Anti-rebond du callback natif : le branchement peut flapper.
  DateTime? _lastHeadphoneFire;

  AutomationRunner(this._ref);

  /// À appeler une fois au démarrage de l'app.
  Future<void> init() async {
    // Le natif est un miroir : Dart réarme tout depuis le store, y compris
    // après un redémarrage où le BootReceiver a déjà fait au mieux.
    final doc = await _ref.read(automationsProvider.future);
    await SchedulerBridge.syncAlarms(doc.actions);

    SchedulerBridge.setHandler((call) async {
      switch (call.method) {
        case 'scheduledActionFired':
          await drainAndRun();
        case 'headphonesConnected':
          await onHeadphonesConnected();
      }
    });

    // L'alarme a ouvert l'app : l'id attend dans le natif.
    await drainAndRun();
  }

  /// Vide l'action en attente côté natif et l'exécute, s'il y en a une.
  Future<void> drainAndRun() async {
    final id = await SchedulerBridge.takeScheduledAction();
    if (id != null) await runFired(id);
  }

  /// Exécute l'action planifiée [id], puis l'avance (quotidienne) ou la
  /// supprime (unique).
  Future<void> runFired(String id) async {
    final doc = await _ref.read(automationsProvider.future);
    final action = doc.actions.where((a) => a.id == id).firstOrNull;
    if (action == null || !action.enabled) {
      await SchedulerBridge.cancelAlarm(id);
      return;
    }
    final result = await _ref
        .read(assistantControllerProvider)
        .runStoredTool(action.toolName, action.args);
    DebugLog.instance.info(
      'Automatisations',
      '${action.label} : ${result.message}',
    );
    await _ref.read(automationsProvider.notifier).advanceAfterFire(id);
  }

  /// Écouteurs branchés : exécute le déclencheur, s'il est configuré et que
  /// rien ne joue déjà (brancher en pleine lecture ne change pas de file).
  Future<void> onHeadphonesConnected() async {
    final now = DateTime.now();
    if (_lastHeadphoneFire != null &&
        now.difference(_lastHeadphoneFire!) < const Duration(seconds: 5)) {
      return;
    }
    _lastHeadphoneFire = now;

    final trigger =
        (await _ref.read(automationsProvider.future)).headphoneTrigger;
    if (trigger == null) return;
    if (_ref.read(audioPlayerServiceProvider).isPlaying) return;

    final result = await _ref
        .read(assistantControllerProvider)
        .runStoredTool(trigger.toolName, trigger.args);
    DebugLog.instance.info(
      'Automatisations',
      'Écouteurs branchés → ${trigger.label} : ${result.message}',
    );
  }
}
