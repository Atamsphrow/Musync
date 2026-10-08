/// Outils « dossiers à exclure » : l'assistant pilote la fonction qui fait
/// disparaître des dossiers entiers de la bibliothèque.
///
/// Le pendant fichier vit dans `song_exclusion_tools.dart` (`exclude_song`) :
/// les deux niveaux coexistent, et le prompt système documente la différence.
/// Ici, la confirmation nomme toujours le dossier exact, en précisant que
/// tout son contenu est concerné.
library;

import 'package:path/path.dart' as p;

import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/providers/excluded_dirs_provider.dart';

/// Le dossier visé, résolu dans cet ordre :
/// 1. `path` — le dossier exact, tel que donné ;
/// 2. `query` — titre ou artiste : le dossier parent du morceau trouvé ;
/// 3. rien — le dossier parent du morceau en cours de lecture.
Future<String> _resolveDir(AiToolContext ctx, Map<String, Object?> args) async {
  final path = optString(args, 'path');
  if (path != null && path.trim().isNotEmpty) return path.trim();
  final query = optString(args, 'query');
  if (query != null && query.trim().isNotEmpty) {
    final hits = matchSongs(await librarySongs(ctx.ref), query);
    if (hits.isEmpty) {
      throw AiToolArgError('Aucun morceau trouvé pour « $query ».');
    }
    return p.dirname(hits.first.filePath);
  }
  final current = ctx.ref.read(audioPlayerServiceProvider).currentSong;
  if (current == null) {
    throw const AiToolArgError(
      'Précisez un dossier (« path »), une recherche (« query »), '
      'ou lancez un morceau d’abord.',
    );
  }
  return p.dirname(current.filePath);
}

/// Exclut un dossier entier de la bibliothèque.
///
/// Sensible : des morceaux disparaissent du scan. Confirmation systématique,
/// et le dialogue nomme le dossier exact.
class ExcludeFolderTool extends AiTool {
  const ExcludeFolderTool();

  @override
  String get name => 'exclude_folder';

  @override
  String get description =>
      'Exclut un DOSSIER entier de la bibliothèque : tout son contenu '
      'disparaît du scan. « path » (dossier exact), ou « query » '
      '(titre/artiste → le dossier parent du morceau trouvé), ou rien = le '
      'dossier du morceau en cours. Pour un seul fichier, voir exclude_song.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': 'string, optionnel — le dossier exact à exclure',
          'query':
              'string, optionnel — titre ou artiste ; c’est le dossier parent '
                  'du morceau trouvé qui est exclu',
        },
      };

  @override
  bool get requiresConfirmation => true;

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final dir = await _resolveDir(ctx, args);
    return 'Exclure le dossier « $dir » ? Tout son contenu disparaîtra de '
        'la bibliothèque — pas seulement un morceau.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final dir = await _resolveDir(ctx, args);
    await ctx.ref.read(excludedDirsProvider.notifier).add(dir);
    return AiToolResult.ok('Dossier exclu : « $dir ».');
  }
}

/// Réintègre un dossier exclu (rescan automatique via le notifier).
///
/// Sans danger : réintégrer ne détruit rien, les morceaux réapparaissent —
/// pas de confirmation.
class IncludeFolderTool extends AiTool {
  const IncludeFolderTool();

  @override
  String get name => 'include_folder';

  @override
  String get description =>
      'Réintègre un dossier exclu dans la bibliothèque. Mêmes arguments que '
      'exclude_folder : « path », « query » (dossier parent du morceau '
      'trouvé), ou rien = dossier du morceau en cours.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': 'string, optionnel — le dossier exact à réintégrer',
          'query':
              'string, optionnel — titre ou artiste ; c’est le dossier parent '
                  'du morceau trouvé qui est réintégré',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final dir = await _resolveDir(ctx, args);
    return 'Réintégrer le dossier « $dir » dans la bibliothèque.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final dir = await _resolveDir(ctx, args);
    await ctx.ref.read(excludedDirsProvider.notifier).remove(dir);
    return AiToolResult.ok('Dossier réintégré : « $dir ».');
  }
}

/// Liste les dossiers exclus, en texte pour l'utilisateur.
class ListExcludedFoldersTool extends AiTool {
  const ListExcludedFoldersTool();

  @override
  String get name => 'list_excluded_folders';

  @override
  String get description =>
      'Liste les dossiers actuellement exclus de la bibliothèque. Sans argument.';

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
      'Lister les dossiers exclus.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final dirs = await ctx.ref.read(excludedDirsProvider.future);
    if (dirs.isEmpty) {
      return AiToolResult.ok('Aucun dossier exclu pour l’instant.');
    }
    return AiToolResult.ok(
      'Dossiers exclus :\n${dirs.map((d) => '• $d').join('\n')}',
    );
  }
}
