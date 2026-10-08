/// Outils d'exclusion au niveau FICHIER : « exclus ce morceau » cache
/// exactement ce fichier-là, le reste de son dossier n'est pas touché.
///
/// Le pendant dossier vit dans `folder_tools.dart` (`exclude_folder`) : les
/// deux niveaux coexistent, et le prompt système documente la différence.
library;

import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/providers/excluded_files_provider.dart';

/// Le fichier visé, résolu dans cet ordre :
/// 1. `path` — le chemin exact, tel que donné ;
/// 2. `query` — titre ou artiste : le fichier du morceau trouvé ;
/// 3. rien — le fichier du morceau en cours de lecture.
Future<String> _resolveSongFile(
  AiToolContext ctx,
  Map<String, Object?> args,
) async {
  final path = optString(args, 'path');
  if (path != null && path.trim().isNotEmpty) return path.trim();
  final query = optString(args, 'query');
  if (query != null && query.trim().isNotEmpty) {
    final hits = matchSongs(await librarySongs(ctx.ref), query);
    if (hits.isEmpty) {
      throw AiToolArgError('Aucun morceau trouvé pour « $query ».');
    }
    return hits.first.filePath;
  }
  final current = ctx.ref.read(audioPlayerServiceProvider).currentSong;
  if (current == null) {
    throw const AiToolArgError(
      'Précisez un fichier (« path »), une recherche (« query »), '
      'ou lancez un morceau d’abord.',
    );
  }
  return current.filePath;
}

/// Exclut un seul fichier de la bibliothèque.
///
/// Sensible : le morceau disparaît du scan. Confirmation systématique, et le
/// dialogue nomme le fichier exact.
class ExcludeSongTool extends AiTool {
  const ExcludeSongTool();

  @override
  String get name => 'exclude_song';

  @override
  String get description =>
      'Exclut un SEUL fichier de la bibliothèque : il disparaît du scan, le '
      'reste de son dossier n’est pas touché. « path » (fichier exact), ou '
      '« query » (titre/artiste → le fichier du morceau trouvé), ou rien = '
      'le morceau en cours. Pour un dossier entier, voir exclude_folder.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': 'string, optionnel — le fichier exact à exclure',
          'query':
              'string, optionnel — titre ou artiste ; c’est le fichier du '
                  'morceau trouvé qui est exclu',
        },
      };

  @override
  bool get requiresConfirmation => true;

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final file = await _resolveSongFile(ctx, args);
    return 'Exclure le fichier « $file » ? Il disparaîtra de la '
        'bibliothèque — le reste du dossier n’est pas touché.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final file = await _resolveSongFile(ctx, args);
    await ctx.ref.read(excludedFilesProvider.notifier).add(file);
    return AiToolResult.ok('Fichier exclu : « $file ».');
  }
}

/// Réintègre un fichier exclu (rescan automatique via le notifier).
///
/// Sans danger : réintégrer ne détruit rien, le morceau réapparaît —
/// pas de confirmation.
class IncludeSongTool extends AiTool {
  const IncludeSongTool();

  @override
  String get name => 'include_song';

  @override
  String get description =>
      'Réintègre un fichier exclu dans la bibliothèque. Mêmes arguments que '
      'exclude_song : « path », « query » (le fichier du morceau trouvé), '
      'ou rien = le morceau en cours.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': 'string, optionnel — le fichier exact à réintégrer',
          'query':
              'string, optionnel — titre ou artiste ; c’est le fichier du '
                  'morceau trouvé qui est réintégré',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final file = await _resolveSongFile(ctx, args);
    return 'Réintégrer le fichier « $file » dans la bibliothèque.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final file = await _resolveSongFile(ctx, args);
    await ctx.ref.read(excludedFilesProvider.notifier).remove(file);
    return AiToolResult.ok('Fichier réintégré : « $file ».');
  }
}

/// Liste les fichiers exclus, en texte pour l'utilisateur.
class ListExcludedSongsTool extends AiTool {
  const ListExcludedSongsTool();

  @override
  String get name => 'list_excluded_songs';

  @override
  String get description =>
      'Liste les fichiers actuellement exclus de la bibliothèque. Sans argument.';

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
      'Lister les fichiers exclus.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final files = await ctx.ref.read(excludedFilesProvider.future);
    if (files.isEmpty) {
      return AiToolResult.ok('Aucun fichier exclu pour l’instant.');
    }
    return AiToolResult.ok(
      'Fichiers exclus :\n${files.map((f) => '• $f').join('\n')}',
    );
  }
}
