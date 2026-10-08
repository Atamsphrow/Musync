/// Outils de lecture : jouer, pause, suivant, précédent, aléatoire, répétition.
///
/// Branchés sur [AudioPlayerService], les mêmes méthodes que les boutons de
/// l'app appellent — l'assistant ne fait rien que l'UI ne sache déjà faire.
library;

import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/player/providers/player_provider.dart';

class PlayTool extends AiTool {
  const PlayTool();

  @override
  String get name => 'play';

  @override
  String get description =>
      'Lance ou reprend la lecture. Avec "query", cherche le morceau dans la '
      'bibliothèque et le joue (premier résultat, la file devient les '
      'résultats). Sans "query", reprend simplement la lecture en cours.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'query':
              'string, optionnel — titre ou artiste à chercher et jouer',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final q = optString(args, 'query');
    return q == null ? 'Reprendre la lecture.' : 'Jouer « $q ».';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final service = ctx.ref.read(audioPlayerServiceProvider);
    final q = optString(args, 'query');
    if (q == null) {
      if (service.currentSong == null) {
        return AiToolResult.fail('Rien en cours de lecture.');
      }
      await service.play();
      return AiToolResult.ok('Lecture reprise.');
    }
    final matches = matchSongs(await librarySongs(ctx.ref), q);
    if (matches.isEmpty) {
      return AiToolResult.fail('Aucun morceau trouvé pour « $q ».');
    }
    final first = matches.first;
    await service.playSong(first, queue: matches, index: 0);
    return AiToolResult.ok('Lecture de ${songLabel(first)}.');
  }
}

class PauseTool extends AiTool {
  const PauseTool();

  @override
  String get name => 'pause';

  @override
  String get description => 'Met la lecture en pause.';

  @override
  Map<String, Object?> get parametersSchema =>
      {'type': 'object', 'properties': const {}};

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Mettre en pause.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    await ctx.ref.read(audioPlayerServiceProvider).pause();
    return AiToolResult.ok('En pause.');
  }
}

class NextTool extends AiTool {
  const NextTool();

  @override
  String get name => 'next';

  @override
  String get description => 'Passe au morceau suivant dans la file.';

  @override
  Map<String, Object?> get parametersSchema =>
      {'type': 'object', 'properties': const {}};

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Passer au morceau suivant.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final service = ctx.ref.read(audioPlayerServiceProvider);
    if (service.queue.length < 2) {
      return AiToolResult.fail('Un seul morceau dans la file.');
    }
    final before = service.currentSong;
    await service.next();
    final now = service.currentSong;
    if (now == null || now == before) return AiToolResult.ok('Morceau suivant.');
    return AiToolResult.ok('${songLabel(now)}.');
  }
}

class PreviousTool extends AiTool {
  const PreviousTool();

  @override
  String get name => 'previous';

  @override
  String get description => 'Revient au morceau précédent dans la file.';

  @override
  Map<String, Object?> get parametersSchema =>
      {'type': 'object', 'properties': const {}};

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Revenir au morceau précédent.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final service = ctx.ref.read(audioPlayerServiceProvider);
    if (service.queue.length < 2) {
      return AiToolResult.fail('Un seul morceau dans la file.');
    }
    final before = service.currentSong;
    await service.previous();
    final now = service.currentSong;
    if (now == null || now == before) {
      return AiToolResult.ok('Morceau précédent.');
    }
    return AiToolResult.ok('${songLabel(now)}.');
  }
}

class ToggleShuffleTool extends AiTool {
  const ToggleShuffleTool();

  @override
  String get name => 'toggle_shuffle';

  @override
  String get description => 'Active ou désactive la lecture aléatoire.';

  @override
  Map<String, Object?> get parametersSchema =>
      {'type': 'object', 'properties': const {}};

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Activer/désactiver l’aléatoire.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final service = ctx.ref.read(audioPlayerServiceProvider);
    await service.toggleShuffle();
    return AiToolResult.ok(
      service.isShuffleEnabled
          ? 'Lecture aléatoire activée.'
          : 'Lecture aléatoire désactivée.',
    );
  }
}

class CycleRepeatTool extends AiTool {
  const CycleRepeatTool();

  @override
  String get name => 'cycle_repeat';

  @override
  String get description =>
      'Change le mode de répétition : désactivé → tout répéter → répéter le '
      'morceau → désactivé…';

  @override
  Map<String, Object?> get parametersSchema =>
      {'type': 'object', 'properties': const {}};

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Changer le mode de répétition.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final service = ctx.ref.read(audioPlayerServiceProvider);
    await service.cycleRepeatMode();
    final label = switch (service.loopMode.name) {
      'all' => 'répéter toute la file',
      'one' => 'répéter le morceau',
      _ => 'répétition désactivée',
    };
    return AiToolResult.ok('Répétition : $label.');
  }
}
