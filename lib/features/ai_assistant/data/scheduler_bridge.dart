/// Pont vers les alarmes Android exactes (`AlarmManager.setAlarmClock`).
///
/// Pourquoi `setAlarmClock` et pas `setExactAndAllowWhileIdle` :
/// - aucune permission spéciale à demander (exempté de SCHEDULE_EXACT_ALARM) ;
/// - ponctuel même en Doze (priorité maximale) ;
/// - le PendingIntent « activity » est le motif canonique des réveils : le
///   système le laisse ouvrir l'app depuis l'arrière-plan, ce que
///   `setExactAndAllowWhileIdle` + BroadcastReceiver ne permet pas.
///
/// Coût assumé : l'icône de réveil reste visible dans la barre de statut tant
/// qu'une automatisation est armée — honnête, l'utilisateur a bien programmé
/// quelque chose.
///
/// Dart est la source de vérité : chaque changement (et chaque démarrage)
/// appelle [syncAlarms] avec la liste complète, le natif ne fait que
/// réarmer. Au boot, le natif relit son propre miroir (SharedPreferences) —
/// il ne parse jamais le JSON de Dart.
///
/// Même pattern que [MediaStore] : ne jette jamais, canal absent en test =
/// no-op silencieux.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/ai_assistant/data/automation.dart';

abstract final class SchedulerBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.atamsphrow.musync/scheduler',
  );

  static const Duration _timeout = Duration(seconds: 5);

  /// Le handler des événements natifs (alarme qui sonne app ouverte,
  /// écouteurs branchés). Installé une fois au démarrage.
  static void setHandler(Future<void> Function(MethodCall call) handler) {
    _channel.setMethodCallHandler(handler);
  }

  /// Arme (ou réarme) une alarme exacte pour [action].
  static Future<void> scheduleAlarm(ScheduledAction action) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('scheduleAlarm', {
        'id': action.id,
        'triggerAtMillis': action.fireAtMillis,
        'label': action.label,
        'daily': action.daily,
      }).timeout(_timeout);
    } on TimeoutException {
      _warn('programmation', action.label);
    } on MissingPluginException {
      // Tests, ou moteur sans le canal : rien à armer.
    } on PlatformException catch (e) {
      _warn('programmation', '${action.label} (${e.code})');
    }
  }

  /// Désarme l'alarme [id].
  static Future<void> cancelAlarm(String id) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel
          .invokeMethod<void>('cancelAlarm', {'id': id})
          .timeout(_timeout);
    } on TimeoutException catch (_) {
      // Annulation silencieuse : le pire cas est une alarme qui sonne une
      // fois de trop, et son tir ne trouve rien à exécuter.
    } on MissingPluginException {
      // Tests : rien à désarmer.
    } on PlatformException catch (_) {
      // Idem timeout.
    }
  }

  /// Remplace TOUTES les alarmes natives par [actions] (activées seulement).
  ///
  /// Appelé à chaque changement du store et à chaque démarrage : le natif
  /// est un miroir, Dart décide.
  static Future<void> syncAlarms(List<ScheduledAction> actions) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('syncAlarms', {
        'alarms': [
          for (final a in actions.where((a) => a.enabled))
            {
              'id': a.id,
              'triggerAtMillis': a.fireAtMillis,
              'label': a.label,
              'daily': a.daily,
            },
        ],
      }).timeout(_timeout);
    } on TimeoutException {
      _warn('synchronisation', 'les automatisations');
    } on MissingPluginException {
      // Tests : rien à synchroniser.
    } on PlatformException catch (e) {
      _warn('synchronisation', 'les automatisations (${e.code})');
    }
  }

  /// L'id de l'action dont l'alarme a ouvert l'app, ou null.
  ///
  /// Drainé au démarrage (l'alarme a lancé l'Activity) et quand le natif
  /// signale `scheduledActionFired` (app déjà ouverte).
  static Future<String?> takeScheduledAction() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel
          .invokeMethod<String>('takeScheduledAction')
          .timeout(_timeout);
    } on TimeoutException catch (_) {
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (_) {
      return null;
    }
  }

  static void _warn(String quoi, String cible) {
    DebugLog.instance.warning(
      'Automatisations',
      'Échec de $quoi pour $cible : l’alarme native n’a pas répondu',
    );
  }
}
