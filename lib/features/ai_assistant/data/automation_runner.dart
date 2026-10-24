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
    // The alarm that launched the app is read BEFORE any realigning:
    // alignStale would otherwise drop a one-shot « due now » as stale
    // before it has rung.
    final firedId = await SchedulerBridge.takeScheduledAction();
    // Stale hours are realigned before the re-sync below: syncing a
    // past fireAtMillis makes Android fire it immediately (the 07:00
    // wake-up going off at 09:30 because the phone was off overnight).
    await _ref.read(automationsProvider.notifier).alignStale(except: firedId);

    // Le natif est un miroir : Dart réarme tout depuis le store, y compris
    // après un redémarrage où le BootReceiver a déjà fait au mieux.
    final doc = await _ref.read(automationsProvider.future);
    final armed = await SchedulerBridge.syncAlarms(doc.actions);
    _ref.read(exactAlarmGrantedProvider.notifier).state =
        armed ? true : await SchedulerBridge.canScheduleExactAlarms();

    SchedulerBridge.setHandler((call) async {
      switch (call.method) {
        case 'scheduledActionFired':
          await drainAndRun();
        case 'headphonesConnected':
          await onHeadphonesConnected();
      }
    });

    // L'alarme a ouvert l'app : son id a été lu en tête d'init, avant
    // le réalignement — on l'exécute, puis on vide ce qui aurait pu
    // être déposé entre-temps.
    if (firedId != null) await runFired(firedId);
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
    // Les alarmes jouent toujours en fondu (réveil en douceur) : l'outil
    // play lit ce flag. Le déclencheur écouteurs passe par
    // onHeadphonesConnected, pas par ici — pas de fondu pour lui.
    final args = Map<String, Object?>.of(action.args);
    args['fadeIn'] = true;
    try {
      final result = await _ref
          .read(assistantControllerProvider)
          .runStoredTool(action.toolName, args);
      DebugLog.instance.info(
        'Automatisations',
        '${action.label} : ${result.message}',
      );
    } finally {
      // Advance (daily) or remove (one-shot) even when the tool
      // failed: a daily left on its fired hour keeps that stale hour
      // in the document, and the next launch's re-sync fires it again
      // immediately — one bad morning would repeat every morning.
      await _ref.read(automationsProvider.notifier).advanceAfterFire(id);
    }
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
