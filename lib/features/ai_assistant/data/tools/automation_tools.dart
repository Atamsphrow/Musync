/// Outils d'automatisation (phase 2) : actions planifiées et déclencheur
/// écouteurs, pilotés en langage naturel.
///
/// Règles :
/// - un outil [requiresConfirmation] ne peut ni être planifié ni déclenché :
///   il n'y a personne pour confirmer à 7h du matin — refus net ;
/// - `schedule_action` (T1) reste pour « dans X minutes » (app ouverte) ;
///   `schedule_once` / `schedule_daily` sont à heure précise et survivent à
///   la fermeture de l'app et au redémarrage du téléphone.
library;

import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/providers/automation_provider.dart';

/// Valide l'outil embarqué : il existe et ne demande pas de confirmation.
///
/// Le flag vient du registre via le contexte (le contrôleur le mappe) : pas
/// de liste codée en dur qui dériverait du registre. Une automatisation ne
/// doit jamais dépendre d'un dialogue.
String _checkedTool(AiToolContext ctx, Map<String, Object?> args) {
  final tool = reqString(args, 'tool').trim();
  if (!ctx.hasTool(tool)) {
    throw AiToolArgError('Outil inconnu : « $tool ».');
  }
  if (ctx.requiresConfirmation(tool)) {
    throw AiToolArgError(
      '« $tool » exige une confirmation et ne peut pas être automatisé.',
    );
  }
  return tool;
}

Map<String, Object?> _nestedArgs(Map<String, Object?> args) =>
    optMap(args, 'args');

String _label(Map<String, Object?> args, String fallback) {
  final label = optString(args, 'label')?.trim();
  return (label == null || label.isEmpty) ? fallback : label;
}

/// « demain à 7h, joue ma file Nuit » — une fois, à heure précise.
class ScheduleOnceTool extends AiTool {
  const ScheduleOnceTool();

  @override
  String get name => 'schedule_once';

  @override
  String get description =>
      'Planifie une action UNE fois, à une date et heure précises (heure du '
      'téléphone). Marche même si l’app est fermée ou le téléphone redémarré. '
      '« datetime » ISO local (ex. "2026-10-09T07:00", dans le futur), '
      '« tool » l’outil à exécuter, « args » ses arguments, « label » un nom '
      'court en français. Jamais un outil à confirmation.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'datetime':
              'string, requis — date+heure ISO locale, ex. "2026-10-09T07:00"',
          'tool': 'string, requis — l’outil à exécuter',
          'args': 'objet, optionnel — les arguments de cet outil',
          'label': 'string, optionnel — nom court en français',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Planifier une action une fois.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final tool = _checkedTool(ctx, args);
    final raw = reqString(args, 'datetime').trim();
    final DateTime at;
    try {
      at = DateTime.parse(raw);
    } catch (_) {
      throw AiToolArgError(
        'Date invalide : « $raw » (attendu : "AAAA-MM-JJTHH:MM").',
      );
    }
    if (!at.isAfter(DateTime.now())) {
      throw const AiToolArgError('La date est dans le passé.');
    }
    final label = _label(args, '$tool — une fois');
    final action =
        await ctx.ref.read(automationsProvider.notifier).scheduleOnce(
              at: at,
              tool: tool,
              args: _nestedArgs(args),
              label: label,
            );
    return AiToolResult.ok(
      'Programmé : « $label » — ${action.describeSchedule()}.',
    );
  }
}

/// « tous les jours à 22h, minuteur 30 min ».
class ScheduleDailyTool extends AiTool {
  const ScheduleDailyTool();

  @override
  String get name => 'schedule_daily';

  @override
  String get description =>
      'Planifie une action TOUS LES JOURS à heure fixe (heure du téléphone). '
      'Marche même si l’app est fermée ou le téléphone redémarré. « hour » '
      '(0-23), « minute » (0-59), « tool » l’outil à exécuter, « args » ses '
      'arguments, « label » un nom court en français. Jamais un outil à '
      'confirmation.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'hour': 'integer, requis — 0 à 23',
          'minute': 'integer, requis — 0 à 59',
          'tool': 'string, requis — l’outil à exécuter',
          'args': 'objet, optionnel — les arguments de cet outil',
          'label': 'string, optionnel — nom court en français',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Planifier une action quotidienne.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final tool = _checkedTool(ctx, args);
    final hour = reqInt(args, 'hour');
    final minute = reqInt(args, 'minute');
    if (hour < 0 || hour > 23) {
      throw const AiToolArgError('Heure invalide (0 à 23).');
    }
    if (minute < 0 || minute > 59) {
      throw const AiToolArgError('Minute invalide (0 à 59).');
    }
    final label = _label(args, '$tool — quotidien');
    final action =
        await ctx.ref.read(automationsProvider.notifier).scheduleDaily(
              hour: hour,
              minute: minute,
              tool: tool,
              args: _nestedArgs(args),
              label: label,
            );
    return AiToolResult.ok(
      'Programmé : « $label » — ${action.describeSchedule()}.',
    );
  }
}

/// « quelles sont mes automatisations ? »
class ListScheduledActionsTool extends AiTool {
  const ListScheduledActionsTool();

  @override
  String get name => 'list_scheduled_actions';

  @override
  String get description =>
      'Liste les actions planifiées et le déclencheur écouteurs. Sans argument.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': <String, Object?>{},
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Lister les automatisations.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final doc = await ctx.ref.read(automationsProvider.future);
    final lines = <String>[];
    for (final a in doc.actions) {
      lines.add('• « ${a.label} » — ${a.describeSchedule()}');
    }
    final trigger = doc.headphoneTrigger;
    if (trigger != null) {
      lines.add('• Écouteurs branchés → « ${trigger.label} »');
    }
    if (lines.isEmpty) {
      return AiToolResult.ok('Aucune automatisation pour l’instant.');
    }
    return AiToolResult.ok('Automatisations :\n${lines.join('\n')}');
  }
}

/// « annule le minuteur de 22h ».
class CancelScheduledActionTool extends AiTool {
  const CancelScheduledActionTool();

  @override
  String get name => 'cancel_scheduled_action';

  @override
  String get description =>
      'Annule une action planifiée. « cible » : son nom (ou un morceau du '
      'nom, ex. "22h"). Sans argument, échec : lister d’abord avec '
      'list_scheduled_actions.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'cible': 'string, requis — nom (ou morceau du nom) de l’action',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Annuler une action planifiée.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final query = reqString(args, 'cible').trim().toLowerCase();
    if (query.isEmpty) {
      throw const AiToolArgError('Précisez quelle action annuler.');
    }
    final doc = await ctx.ref.read(automationsProvider.future);
    final hits = [
      for (final a in doc.actions)
        if (a.id == query || a.label.toLowerCase().contains(query)) a,
    ];
    if (hits.isEmpty) {
      throw AiToolArgError('Aucune action planifiée pour « $query ».');
    }
    if (hits.length > 1) {
      throw AiToolArgError(
        'Plusieurs actions correspondent : précisez '
        '(${hits.map((a) => '« ${a.label} »').join(', ')}).',
      );
    }
    final action = hits.single;
    await ctx.ref.read(automationsProvider.notifier).cancel(action.id);
    return AiToolResult.ok('Annulé : « ${action.label} ».');
  }
}

/// « quand je branche mes écouteurs, lance ma file Nuit ».
class SetHeadphoneTriggerTool extends AiTool {
  const SetHeadphoneTriggerTool();

  @override
  String get name => 'set_headphone_trigger';

  @override
  String get description =>
      'Définit ce qui se passe quand des écouteurs sont branchés (jack, USB '
      'ou Bluetooth). « tool » l’outil à exécuter, « args » ses arguments, '
      '« label » un nom court en français. Ne se déclenche que si rien ne '
      'joue déjà, et seulement quand l’app est en mémoire. Remplace le '
      'déclencheur précédent. Jamais un outil à confirmation.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'tool': 'string, requis — l’outil à exécuter',
          'args': 'objet, optionnel — les arguments de cet outil',
          'label': 'string, optionnel — nom court en français',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Définir le déclencheur écouteurs.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final tool = _checkedTool(ctx, args);
    final label = _label(args, tool);
    await ctx.ref.read(automationsProvider.notifier).setHeadphoneTrigger(
          tool: tool,
          args: _nestedArgs(args),
          label: label,
        );
    return AiToolResult.ok(
      'Noté : quand tu brancheras tes écouteurs → « $label ».',
    );
  }
}

class ClearHeadphoneTriggerTool extends AiTool {
  const ClearHeadphoneTriggerTool();

  @override
  String get name => 'clear_headphone_trigger';

  @override
  String get description =>
      'Supprime le déclencheur écouteurs. Sans argument.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': <String, Object?>{},
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Supprimer le déclencheur écouteurs.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    await ctx.ref.read(automationsProvider.notifier).clearHeadphoneTrigger();
    return AiToolResult.ok('Déclencheur écouteurs supprimé.');
  }
}
