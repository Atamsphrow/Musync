/// Outils de temps : minuteur d'arrêt et planification d'une action.
///
/// `schedule_action` est l'automatisation de niveau 1 : « dans X minutes,
/// fais Y ». Elle ne survit pas à la fermeture de l'app — c'est le niveau 2
/// (alarmes exactes Android), hors périmètre.
library;

import 'dart:async';

import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/player/providers/sleep_timer_provider.dart';

class SleepTimerTool extends AiTool {
  const SleepTimerTool();

  @override
  String get name => 'sleep_timer';

  @override
  String get description =>
      'Minuteur d’arrêt : coupe la lecture dans X minutes, ou le '
      'désactive. "minutes" ou "disabled: true".';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'minutes': 'integer, optionnel — arrêt dans X minutes (1-480)',
          'disabled': 'booléen, optionnel — vrai pour désactiver',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    if (optBool(args, 'disabled')) return 'Désactiver le minuteur.';
    final m = optInt(args, 'minutes');
    return m == null
        ? 'Régler le minuteur.'
        : 'Arrêter la lecture dans $m min.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final disabled = optBool(args, 'disabled');
    final minutes = optInt(args, 'minutes');
    if (!disabled) {
      if (minutes == null) {
        throw const AiToolArgError(
          'Précisez "minutes" ou "disabled: true".',
        );
      }
      if (minutes <= 0 || minutes > 480) {
        throw const AiToolArgError('Durée invalide (1 à 480 minutes).');
      }
    }
    final notifier = ctx.ref.read(sleepTimerProvider.notifier);
    if (disabled) {
      notifier.setOption(SleepTimerOption.disabled);
      return AiToolResult.ok('Minuteur désactivé.');
    }
    notifier.setCustomMinutes(minutes!);
    return AiToolResult.ok(
      'Minuteur : la lecture s’arrêtera dans $minutes min.',
    );
  }
}

/// Planifie l'exécution d'un autre outil dans X minutes.
///
/// Les minuteurs vivent dans un registre statique : ils tiennent tant que
/// l'app tourne, et meurent avec elle. Une action planifiée s'exécute comme
/// si elle venait d'être confirmée.
class ScheduleActionTool extends AiTool {
  static final List<Timer> _scheduled = [];

  @override
  String get name => 'schedule_action';

  @override
  String get description =>
      'Exécute une autre action dans X minutes (« dans 20 minutes, mets en '
      'pause »). L’app doit rester ouverte ; à la fermeture, la '
      'planification est perdue. Ne peut pas se planifier elle-même.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'in_minutes': 'integer, requis — dans combien de minutes (1-720)',
          'action': 'string, requis — nom de l’outil à exécuter',
          'args': 'objet, optionnel — arguments de cet outil',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final m = optInt(args, 'in_minutes');
    final a = optString(args, 'action');
    if (m == null || a == null) return 'Planifier une action.';
    return 'Exécuter « $a » dans $m min.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final minutes = reqInt(args, 'in_minutes');
    if (minutes <= 0 || minutes > 720) {
      throw const AiToolArgError('Délai invalide (1 à 720 minutes).');
    }
    final action = reqString(args, 'action');
    if (action == name) {
      throw const AiToolArgError('On ne planifie pas une planification.');
    }
    if (!ctx.hasTool(action)) {
      throw AiToolArgError('Action inconnue : « $action ».');
    }
    final actionArgs = optMap(args, 'args');
    _scheduled.add(
      Timer(Duration(minutes: minutes), () async {
        try {
          await ctx.runTool(action, actionArgs);
        } catch (_) {
          // Une action planifiée qui échoue le fait en silence : l'utilisateur
          // n'est plus devant l'écran pour lire l'erreur.
        }
      }),
    );
    return AiToolResult.ok(
      '« $action » sera exécuté dans $minutes min '
      '(l’app doit rester ouverte).',
    );
  }
}
