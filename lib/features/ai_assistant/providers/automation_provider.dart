/// État des automatisations : actions planifiées + déclencheur écouteurs.
///
/// Chaque mutation sauvegarde le JSON puis resynchronise les alarmes natives
/// (Dart = source de vérité, le natif n'est qu'un miroir pour le boot).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/ai_assistant/data/automation.dart';
import 'package:musync/features/ai_assistant/data/automation_store.dart';
import 'package:musync/features/ai_assistant/data/scheduler_bridge.dart';

final automationStoreProvider = Provider<AutomationStore>(
  (ref) => const AutomationStore(),
);

final automationsProvider =
    AsyncNotifierProvider<AutomationsNotifier, AutomationsDoc>(
  AutomationsNotifier.new,
);

class AutomationsNotifier extends AsyncNotifier<AutomationsDoc> {
  @override
  Future<AutomationsDoc> build() => ref.read(automationStoreProvider).load();

  /// Attend la fin du build initial. Sans ça, une écriture manuelle faite
  /// pendant le chargement serait écrasée par le résultat du build qui
  /// arrive après — le bug classique des tests comme de l'alarme qui sonne
  /// au tout premier démarrage.
  Future<void> _ready() async {
    await future;
  }

  /// Sauvegarde + miroir natif. Le natif ne jette jamais (voir
  /// [SchedulerBridge]) : une alarme non armée est loggée, pas crashée.
  Future<void> _commit(AutomationsDoc next) async {
    state = AsyncValue.data(next);
    try {
      await ref.read(automationStoreProvider).save(next);
    } catch (error, stack) {
      DebugLog.instance.error(
        'Automatisations',
        'Enregistrement des automatisations impossible',
        error: error,
        stackTrace: stack,
      );
    }
    await SchedulerBridge.syncAlarms(next.actions);
  }

  /// « demain à 7h, joue ma file Nuit ». [at] en heure locale, dans le futur.
  Future<ScheduledAction> scheduleOnce({
    required DateTime at,
    required String tool,
    Map<String, Object?> args = const {},
    required String label,
  }) async {
    await _ready();
    final action = ScheduledAction(
      id: 'sched-${DateTime.now().microsecondsSinceEpoch}',
      daily: false,
      fireAtMillis: at.millisecondsSinceEpoch,
      hour: at.hour,
      minute: at.minute,
      toolName: tool,
      args: args,
      label: label,
    );
    final current = state.valueOrNull ?? const AutomationsDoc();
    await _commit(AutomationsDoc(
      actions: [...current.actions, action],
      headphoneTrigger: current.headphoneTrigger,
    ));
    return action;
  }

  /// « tous les jours à 22h, minuteur 30 min ».
  Future<ScheduledAction> scheduleDaily({
    required int hour,
    required int minute,
    required String tool,
    Map<String, Object?> args = const {},
    required String label,
  }) async {
    await _ready();
    final now = DateTime.now();
    final action = ScheduledAction(
      id: 'sched-${now.microsecondsSinceEpoch}',
      daily: true,
      fireAtMillis: ScheduledAction.nextDailyFire(hour, minute, now),
      hour: hour,
      minute: minute,
      toolName: tool,
      args: args,
      label: label,
    );
    final current = state.valueOrNull ?? const AutomationsDoc();
    await _commit(AutomationsDoc(
      actions: [...current.actions, action],
      headphoneTrigger: current.headphoneTrigger,
    ));
    return action;
  }

  /// Après le tir d'une action : la quotidienne est avancée au lendemain et
  /// réarmée, l'unique est supprimée.
  Future<void> advanceAfterFire(String id) async {
    await _ready();
    final current = state.valueOrNull ?? const AutomationsDoc();
    final action = current.byId(id);
    if (action == null) return;
    if (!action.daily) {
      await cancel(id);
      return;
    }
    final next = action.copyWith(
      fireAtMillis: ScheduledAction.nextDailyFire(
        action.hour,
        action.minute,
        DateTime.now().add(const Duration(minutes: 1)),
      ),
    );
    await _commit(AutomationsDoc(
      actions: [for (final a in current.actions) if (a.id == id) next else a],
      headphoneTrigger: current.headphoneTrigger,
    ));
  }

  Future<void> cancel(String id) async {
    await _ready();
    final current = state.valueOrNull ?? const AutomationsDoc();
    await _commit(AutomationsDoc(
      actions: [for (final a in current.actions) if (a.id != id) a],
      headphoneTrigger: current.headphoneTrigger,
    ));
  }

  Future<void> setHeadphoneTrigger({
    required String tool,
    Map<String, Object?> args = const {},
    required String label,
  }) async {
    await _ready();
    final current = state.valueOrNull ?? const AutomationsDoc();
    await _commit(AutomationsDoc(
      actions: current.actions,
      headphoneTrigger: HeadphoneTrigger(
        toolName: tool,
        args: args,
        label: label,
      ),
    ));
  }

  Future<void> clearHeadphoneTrigger() async {
    await _ready();
    final current = state.valueOrNull ?? const AutomationsDoc();
    await _commit(AutomationsDoc(actions: current.actions));
  }
}

extension on AutomationsDoc {
  ScheduledAction? byId(String id) {
    for (final a in actions) {
      if (a.id == id) return a;
    }
    return null;
  }
}
