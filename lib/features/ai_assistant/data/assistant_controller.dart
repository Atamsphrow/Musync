/// Le contrôleur : comprend la réponse du modèle, la valide strictement, et
/// exécute les outils.
///
/// Jamais d'exécution aveugle : outil inconnu, argument halluciné ou JSON
/// malformé donnent un message d'erreur clair en français, pas un appel.
/// Les outils à confirmation rendent un [AssistantNeedsConfirmation] que T3
/// affiche en dialogue — l'exécution n'a lieu qu'après le « Confirmer ».
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/shared_http_client.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/ai_tool_registry.dart';
import 'package:musync/features/ai_assistant/data/assistant_bridge.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';

/// Ce que le modèle a décidé, après validation stricte.
sealed class AssistantPlan {
  const AssistantPlan();
}

/// Répondre par du texte (stats déjà calculées, aide sur l'app).
class AssistantAnswer extends AssistantPlan {
  final String text;
  const AssistantAnswer(this.text);
}

/// Appeler un outil.
class AssistantToolCall extends AssistantPlan {
  final String tool;
  final Map<String, Object?> args;
  const AssistantToolCall(this.tool, [this.args = const {}]);
}

/// Plusieurs outils, exécutés en séquence (T4).
class AssistantSteps extends AssistantPlan {
  final List<AssistantToolCall> steps;
  const AssistantSteps(this.steps);
}

/// Le modèle a répondu quelque chose d'inutilisable.
class AssistantParseError implements Exception {
  final String message;
  const AssistantParseError(this.message);
  @override
  String toString() => 'AssistantParseError: $message';
}

/// Ce que T3 affiche : un message, ou un dialogue de confirmation.
sealed class AssistantOutcome {
  const AssistantOutcome();
}

/// Commande traitée : [message] va dans le snackbar.
class AssistantDone extends AssistantOutcome {
  final String message;
  final String? navigateTo;
  final Object? navigateArgs;
  const AssistantDone(this.message, {this.navigateTo, this.navigateArgs});
}

/// L'outil exige une confirmation : T3 montre [preview] en dialogue.
class AssistantNeedsConfirmation extends AssistantOutcome {
  final String tool;
  final Map<String, Object?> args;
  final String preview;
  const AssistantNeedsConfirmation({
    required this.tool,
    required this.args,
    required this.preview,
  });
}

/// Échec propre, message en français pour le snackbar.
class AssistantFailed extends AssistantOutcome {
  final String message;
  const AssistantFailed(this.message);
}

class AssistantController {
  final Ref _ref;
  final AiToolRegistry _registry;
  final AssistantHistory _history = AssistantHistory();

  AssistantController(this._ref, {AiToolRegistry? registry})
      : _registry = registry ?? buildAiToolRegistry();

  /// Parse strict d'une réponse brute du modèle. Testable sans réseau.
  ///
  /// Jette [AssistantParseError] quand la réponse est inutilisable : pas du
  /// JSON, outil inconnu, argument hors schéma, forme inconnue.
  AssistantPlan parsePlan(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw.trim());
    } catch (_) {
      throw const AssistantParseError(
        'Le modèle a répondu n’importe quoi (pas du JSON).',
      );
    }
    if (decoded is! Map) {
      throw const AssistantParseError(
        'Réponse du modèle incompréhensible.',
      );
    }
    final map = Map<String, Object?>.from(decoded);

    if (map.containsKey('answer')) {
      final answer = map['answer'];
      if (answer is String && answer.trim().isNotEmpty) {
        return AssistantAnswer(answer.trim());
      }
      throw const AssistantParseError(
        'Réponse du modèle incompréhensible.',
      );
    }

    if (map.containsKey('steps')) {
      final steps = map['steps'];
      if (steps is! List || steps.isEmpty) {
        throw const AssistantParseError(
          'Étapes du modèle incompréhensibles.',
        );
      }
      return AssistantSteps([for (final s in steps) _parseToolCall(s)]);
    }

    if (map.containsKey('tool')) {
      // Certains modèles renvoient {"tool": "answer", "args": {...}}
      // au lieu de {"answer": "..."} : on intercepte avant toute
      // résolution d'outil, sinon « answer » finit en « Outil inconnu ».
      if (map['tool'] == 'answer') {
        return AssistantAnswer(_extractAnswerText(map['args']));
      }
      return _parseToolCall(map);
    }

    throw const AssistantParseError(
      'Réponse du modèle incompréhensible.',
    );
  }

  /// Le texte d'une réponse « answer » déguisée en appel d'outil.
  ///
  /// Regarde les clés habituelles (`text`, `answer`, `message`), puis
  /// n'importe quelle valeur textuelle non vide.
  String _extractAnswerText(Object? args) {
    if (args is Map) {
      final map = Map<String, Object?>.from(args);
      for (final key in ['text', 'answer', 'message', 'content']) {
        final v = map[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      for (final v in map.values) {
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
    } else if (args is String && args.trim().isNotEmpty) {
      return args.trim();
    }
    throw const AssistantParseError('Réponse du modèle incompréhensible.');
  }

  AssistantToolCall _parseToolCall(Object? node) {
    if (node is! Map) {
      throw const AssistantParseError('Appel d’outil incompréhensible.');
    }
    final map = Map<String, Object?>.from(node);
    final name = map['tool'];
    final tool = name is String ? _registry[name] : null;
    if (tool == null) {
      throw AssistantParseError('Outil inconnu : « $name ».');
    }
    final rawArgs = map['args'];
    final Map<String, Object?> args;
    if (rawArgs == null) {
      args = const {};
    } else if (rawArgs is Map) {
      args = Map<String, Object?>.from(rawArgs);
    } else {
      throw AssistantParseError(
        'Arguments incompréhensibles pour « $name ».',
      );
    }
    // Pas d'arguments hallucinés : chaque clé doit figurer au schéma.
    final props = tool.parametersSchema['properties'];
    if (props is Map) {
      for (final key in args.keys) {
        if (!props.containsKey(key)) {
          throw AssistantParseError(
            'Argument inconnu pour « $name » : « $key ».',
          );
        }
      }
    }
    return AssistantToolCall(tool.name, args);
  }

  /// Traite une commande en langage naturel : appel modèle, validation,
  /// exécution ou demande de confirmation.
  Future<AssistantOutcome> handleCommand(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const AssistantFailed('Commande vide.');

    final settings = await _ref.read(aiSettingsStoreProvider).load();
    final provider = settings.active;
    if (provider == null) {
      return const AssistantFailed(
        'Aucune clé IA configurée. Ajoutez-en une dans Paramètres › IA.',
      );
    }

    final bridge =
        AssistantBridge(client: _ref.read(sharedHttpClientProvider));
    final system =
        AssistantBridge.systemPrompt(_registry.describeForLlm());
    final String raw;
    try {
      raw = await bridge.complete(
        provider: provider,
        system: system,
        history: _history.messages,
        userText: trimmed,
      );
    } on AiReaderException catch (e) {
      return AssistantFailed(e.message);
    } catch (_) {
      return const AssistantFailed(
        'Le modèle ne répond pas. Réessayez.',
      );
    }
    if (raw.trim().isEmpty) {
      return const AssistantFailed('Le modèle n’a rien répondu.');
    }

    final AssistantPlan plan;
    try {
      plan = parsePlan(raw);
    } on AssistantParseError catch (e) {
      _history.add(trimmed, raw);
      return AssistantFailed(e.message);
    }
    _history.add(trimmed, raw);
    return executePlan(plan);
  }

  /// Exécute un plan déjà validé. Public pour les tests (faux outils).
  Future<AssistantOutcome> executePlan(AssistantPlan plan) {
    return switch (plan) {
      AssistantAnswer(text: final t) => Future.value(AssistantDone(t)),
      AssistantToolCall(tool: final name, args: final args) =>
        _runSingle(name, args),
      AssistantSteps(steps: final steps) => _runSteps(steps),
    };
  }

  /// Exécute un outil stocké (automatisation planifiée ou déclencheur).
  ///
  /// Jamais de confirmation ici : les outils à confirmation ne peuvent
  /// pas être planifiés (refusé à la création), et ce garde-fou bloque
  /// ce qui aurait filtré entre-temps. Rend un [AiToolResult], pas un
  /// [AssistantOutcome] : il n'y a pas d'utilisateur devant l'écran.
  Future<AiToolResult> runStoredTool(
    String toolName,
    Map<String, Object?> args,
  ) async {
    final tool = _registry[toolName];
    if (tool == null) {
      return AiToolResult.fail('Outil inconnu : « $toolName ».');
    }
    if (tool.requiresConfirmation) {
      return AiToolResult.fail(
        '« $toolName » exige une confirmation et ne peut pas être automatisé.',
      );
    }
    return _executeTool(toolName, args);
  }

  /// Exécute un outil après confirmation de l'utilisateur (dialogue T3).
  Future<AssistantOutcome> runConfirmed(
    String toolName,
    Map<String, Object?> args,
  ) async {
    final tool = _registry[toolName];
    if (tool == null) return const AssistantFailed('Outil inconnu.');
    return _execute(tool, args);
  }

  Future<AssistantOutcome> _runSingle(
    String name,
    Map<String, Object?> args,
  ) async {
    final tool = _registry[name]!;
    if (tool.requiresConfirmation) {
      final String preview;
      try {
        preview = await tool.describeAction(_context(), args);
      } on AiToolArgError catch (e) {
        return AssistantFailed(e.message);
      } catch (e) {
        return AssistantFailed('Préparation impossible : $e');
      }
      return AssistantNeedsConfirmation(
        tool: name,
        args: args,
        preview: preview,
      );
    }
    return _execute(tool, args);
  }

  /// Étapes en séquence : arrêt à la première qui échoue, avec ce qui a déjà
  /// été fait. Une étape à confirmation est refusée d'emblée — une commande
  /// multi-étapes ne passe pas par un dialogue au milieu.
  Future<AssistantOutcome> _runSteps(List<AssistantToolCall> steps) async {
    for (final step in steps) {
      final tool = _registry[step.tool];
      if (tool == null) {
        return AssistantFailed('Outil inconnu : « ${step.tool} ».');
      }
      if (tool.requiresConfirmation) {
        return const AssistantFailed(
          'Une commande multi-étapes ne peut pas contenir d’action à '
          'confirmer — demandez-la séparément.',
        );
      }
    }
    final messages = <String>[];
    String? navigateTo;
    Object? navigateArgs;
    for (final step in steps) {
      final result = await _executeTool(step.tool, step.args);
      messages.add(result.message);
      if (result.navigateTo != null) {
        navigateTo = result.navigateTo;
        navigateArgs = result.navigateArgs;
      }
      if (!result.ok) break;
    }
    return AssistantDone(
      messages.join('\n'),
      navigateTo: navigateTo,
      navigateArgs: navigateArgs,
    );
  }

  Future<AssistantOutcome> _execute(
    AiTool tool,
    Map<String, Object?> args,
  ) async {
    final result = await _executeTool(tool.name, args);
    return AssistantDone(
      result.message,
      navigateTo: result.navigateTo,
      navigateArgs: result.navigateArgs,
    );
  }

  Future<AiToolResult> _executeTool(
    String name,
    Map<String, Object?> args,
  ) async {
    final tool = _registry[name];
    if (tool == null) return AiToolResult.fail('Outil inconnu : « $name ».');
    try {
      return await tool.execute(_context(), args);
    } on AiToolArgError catch (e) {
      return AiToolResult.fail(e.message);
    } catch (e) {
      return AiToolResult.fail('Échec : $e');
    }
  }

  AiToolContext _context() => AiToolContext(
        ref: _ref,
        runTool: (name, args) => _executeTool(name, args),
        hasTool: _registry.contains,
        requiresConfirmation: (name) =>
            _registry[name]?.requiresConfirmation ?? true,
      );
}

final assistantControllerProvider = Provider<AssistantController>(
  (ref) => AssistantController(ref),
);
