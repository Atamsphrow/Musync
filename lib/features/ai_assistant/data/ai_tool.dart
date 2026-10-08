/// Les briques de l'assistant IA : ce qu'est un outil, ce qu'il reçoit et ce
/// qu'il rend.
///
/// Un outil est un verbe que l'app sait exécuter — jouer, mettre en pause,
/// chercher des paroles… Le LLM ne fait que choisir le verbe et ses
/// arguments (JSON) ; c'est l'app qui agit, jamais le modèle directement.
///
/// Tout le texte destiné à l'utilisateur est en français.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/utils/text_search.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';

/// Un appel d'outil tel que le pont LLM l'a compris : un nom et des arguments.
class AiToolCall {
  final String name;
  final Map<String, Object?> args;

  const AiToolCall({required this.name, this.args = const {}});
}

/// Ce qu'un outil rend après exécution.
///
/// [message] est en français et s'affiche tel quel (snackbar, Journal).
/// [navigateTo]/[navigateArgs] demandent l'ouverture d'un écran existant
/// (éditeur de synchro…) : c'est T3 qui navigue, pas l'outil.
class AiToolResult {
  final bool ok;
  final String message;
  final String? navigateTo;
  final Object? navigateArgs;

  const AiToolResult({
    required this.ok,
    required this.message,
    this.navigateTo,
    this.navigateArgs,
  });

  factory AiToolResult.ok(
    String message, {
    String? navigateTo,
    Object? navigateArgs,
  }) =>
      AiToolResult(
        ok: true,
        message: message,
        navigateTo: navigateTo,
        navigateArgs: navigateArgs,
      );

  factory AiToolResult.fail(String message) =>
      AiToolResult(ok: false, message: message);
}

/// Arguments invalides : type inattendu, valeur manquante ou hors bornes.
///
/// Levée par les aides ci-dessous, jamais montrée telle quelle : l'exécuteur
/// la convertit en [AiToolResult] d'échec avec un message en français.
class AiToolArgError implements Exception {
  final String message;
  const AiToolArgError(this.message);
  @override
  String toString() => 'AiToolArgError: $message';
}

/// Ce dont un outil a besoin pour agir.
///
/// [runTool] permet à un outil d'en appeler un autre (ex. `schedule_action`
/// planifie `pause`) ; [hasTool] valide les noms sans exécuter.
class AiToolContext {
  final Ref ref;
  final Future<AiToolResult> Function(String tool, Map<String, Object?> args)
      runTool;
  final bool Function(String tool) hasTool;

  const AiToolContext({
    required this.ref,
    required this.runTool,
    required this.hasTool,
  });
}

/// Un verbe de l'assistant.
abstract class AiTool {
  const AiTool();

  /// Nom appelé par le LLM, en snake_case : `play`, `sleep_timer`…
  String get name;

  /// Ce que fait l'outil, en français — c'est ce que lit le LLM.
  String get description;

  /// Schéma JSON simplifié des arguments, montré au LLM.
  /// Ex. : `{"query": "string, optionnel — titre ou artiste"}`.
  Map<String, Object?> get parametersSchema;

  /// Vrai quand l'exécution exige une confirmation explicite (dialogue T3) :
  /// tags, suppression de fichier, écritures en lot.
  bool get requiresConfirmation => false;

  /// Texte du dialogue de confirmation : ce qui va exactement se passer.
  /// Lecture seule — ne doit jamais écrire.
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  );

  /// Exécute. Ne jette jamais pour un argument invalide : rend un échec avec
  /// un message en français. Ne jette que pour un vrai problème technique,
  /// que l'exécuteur convertit aussi en échec propre.
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  );
}

// ---- aides d'arguments --------------------------------------------------

String reqString(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v is String && v.trim().isNotEmpty) return v.trim();
  throw AiToolArgError('Argument « $key » manquant ou vide.');
}

String? optString(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is String && v.trim().isNotEmpty) return v.trim();
  if (v is String) return null;
  throw AiToolArgError('Argument « $key » : texte attendu.');
}

int reqInt(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v is int) return v;
  if (v is double && v == v.roundToDouble()) return v.toInt();
  throw AiToolArgError('Argument « $key » : nombre entier attendu.');
}

int? optInt(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is int) return v;
  if (v is double && v == v.roundToDouble()) return v.toInt();
  throw AiToolArgError('Argument « $key » : nombre entier attendu.');
}

bool optBool(Map<String, Object?> args, String key, {bool orElse = false}) {
  final v = args[key];
  if (v == null) return orElse;
  if (v is bool) return v;
  throw AiToolArgError('Argument « $key » : vrai/faux attendu.');
}

Map<String, Object?> optMap(Map<String, Object?> args, String key) {
  final v = args[key];
  if (v == null) return const {};
  if (v is Map) return v.cast<String, Object?>();
  throw AiToolArgError('Argument « $key » : objet attendu.');
}

// ---- aides bibliothèque -------------------------------------------------

/// Toute la bibliothèque, ou vide si elle n'est pas lisible.
Future<List<Song>> librarySongs(Ref ref) async {
  try {
    return await ref.read(songListProvider.future);
  } catch (_) {
    return const [];
  }
}

/// Les morceaux dont le titre ou l'artiste contient la requête.
///
/// Même pliage que la recherche de la bibliothèque (`foldForSearch`) pour
/// que « juice » trouve « Juice WRLD » comme dans l'app.
List<Song> matchSongs(List<Song> songs, String query) {
  final q = foldForSearch(query.trim());
  if (q.isEmpty) return const [];
  return [
    for (final s in songs)
      if ('${foldForSearch(s.title)}\n${foldForSearch(s.artist)}'.contains(q))
        s,
  ];
}

/// « « titre » — artiste », pour les messages.
String songLabel(Song s) => '« ${s.title} » — ${s.artist}';
