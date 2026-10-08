/// Outils de bibliothèque : recherche, lecture d'un artiste en aléatoire,
/// statistiques, création de file nommée.
library;

import 'package:musync/core/utils/text_search.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/player/providers/named_queue_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';

class SearchLibraryTool extends AiTool {
  const SearchLibraryTool();

  @override
  String get name => 'search_library';

  @override
  String get description =>
      'Cherche dans la bibliothèque (titre ou artiste). Rend le nombre de '
      'résultats et les premiers : sert à répondre aux questions comme '
      '« quels morceaux de X ? ». Ne joue rien.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'query': 'string, requis — texte à chercher',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final q = optString(args, 'query');
    return q == null ? 'Chercher dans la bibliothèque.' : 'Chercher « $q ».';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final q = reqString(args, 'query');
    final matches = matchSongs(await librarySongs(ctx.ref), q);
    if (matches.isEmpty) {
      return AiToolResult.fail('Aucun résultat pour « $q ».');
    }
    final shown =
        matches.take(5).map(songLabel).join(' ; ');
    final more = matches.length > 5 ? ' (+${matches.length - 5} autres)' : '';
    final word = matches.length > 1 ? 'résultats' : 'résultat';
    return AiToolResult.ok(
      '${matches.length} $word pour « $q » : $shown$more',
    );
  }
}

class PlayArtistShuffledTool extends AiTool {
  const PlayArtistShuffledTool();

  @override
  String get name => 'play_artist_shuffled';

  @override
  String get description =>
      'Joue tous les morceaux d’un artiste en aléatoire '
      '(« mets du Juice en aléatoire »). Active l’aléatoire si besoin.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'artist': 'string, requis — nom d’artiste',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final a = optString(args, 'artist');
    return a == null ? 'Jouer un artiste en aléatoire.' : 'Jouer « $a » en aléatoire.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final artist = reqString(args, 'artist');
    final q = foldForSearch(artist);
    final matches = [
      for (final s in await librarySongs(ctx.ref))
        if (foldForSearch(s.artist).contains(q)) s,
    ];
    if (matches.isEmpty) {
      return AiToolResult.fail(
        'Aucun morceau de « $artist » dans la bibliothèque.',
      );
    }
    final service = ctx.ref.read(audioPlayerServiceProvider);
    await service.playSong(matches.first, queue: matches, index: 0);
    if (!service.isShuffleEnabled) await service.toggleShuffle();
    final word = matches.length > 1 ? 'morceaux' : 'morceau';
    return AiToolResult.ok(
      '« $artist » en aléatoire (${matches.length} $word).',
    );
  }
}

class LibraryStatsTool extends AiTool {
  const LibraryStatsTool();

  @override
  String get name => 'library_stats';

  @override
  String get description =>
      'Statistiques de la bibliothèque : nombre de morceaux, et combien ont '
      'des paroles synchronisées, simples ou aucune. Sert à répondre à '
      '« combien de morceaux sans paroles ? ».';

  @override
  Map<String, Object?> get parametersSchema =>
      {'type': 'object', 'properties': const {}};

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Compter la bibliothèque.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final songs = await librarySongs(ctx.ref);
    final counts = ctx.ref.read(lyricsStatusCountsProvider);
    String n(LyricsStatus s) => '${counts[s] ?? '…'}';
    return AiToolResult.ok(
      'Bibliothèque : ${songs.length} morceaux — '
      '${n(LyricsStatus.synced)} synchronisés, '
      '${n(LyricsStatus.plain)} simples, '
      '${n(LyricsStatus.none)} sans paroles.',
    );
  }
}

class FindDuplicatesTool extends AiTool {
  const FindDuplicatesTool();

  @override
  String get name => 'find_duplicates';

  @override
  String get description =>
      'Trouve les morceaux en double : même titre et même artiste (insensible '
      'à la casse et aux accents), mais fichiers différents — les noms de '
      'fichiers peuvent différer. Rend chaque groupe avec les chemins et la '
      'durée, pour décider quoi garder. Ne supprime rien : la suppression se '
      'fait ensuite morceau par morceau avec delete_file.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': const {},
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Chercher les morceaux en double.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final groups = <String, List<Song>>{};
    for (final s in await librarySongs(ctx.ref)) {
      // Des tags vides ne forment pas un « doublon » : on les ignore.
      if (s.title.trim().isEmpty && s.artist.trim().isEmpty) continue;
      final key = '${foldForSearch(s.title)}|${foldForSearch(s.artist)}';
      groups.putIfAbsent(key, () => []).add(s);
    }
    final dupes = groups.values.where((g) => g.length > 1).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (dupes.isEmpty) {
      return AiToolResult.ok(
        'Aucun doublon : chaque couple titre+artiste est unique.',
      );
    }
    String dur(Song s) {
      final sec = (s.duration / 1000).round();
      return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
    }

    final total = dupes.fold<int>(0, (n, g) => n + g.length);
    final shown = dupes.take(8).map((g) {
      final files = g.map((s) => '${s.filePath} (${dur(s)})').join(' ; ');
      return '${songLabel(g.first)} — ${g.length} fichiers : $files';
    }).join('\n');
    final more =
        dupes.length > 8 ? '\n(+${dupes.length - 8} autres groupes)' : '';
    final gw = dupes.length > 1 ? 'groupes' : 'groupe';
    final fw = total > 1 ? 'fichiers' : 'fichier';
    return AiToolResult.ok(
      '$total $fw en double, ${dupes.length} $gw :\n$shown$more',
    );
  }
}

class CreateNamedQueueTool extends AiTool {
  const CreateNamedQueueTool();

  @override
  String get name => 'create_named_queue';

  @override
  String get description =>
      'Crée une file nommée. Avec "query", à partir des résultats de '
      'recherche ; sans, à partir de la file de lecture actuelle. '
      '« shuffled: true » lance la file en aléatoire après création '
      '(« crée une file de Billie Eilish mélangée »).';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'name': 'string, requis — nom de la file',
          'query':
              'string, optionnel — si donné, la file contient les résultats',
          'shuffled':
              'bool, optionnel — si vrai, la file est lancée en aléatoire '
              'après création',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final n = optString(args, 'name') ?? '…';
    return 'Créer la file « $n ».';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final name = reqString(args, 'name');
    final q = optString(args, 'query');
    final songs = q == null
        ? ctx.ref.read(audioPlayerServiceProvider).queue
        : matchSongs(await librarySongs(ctx.ref), q);
    if (songs.isEmpty) {
      return AiToolResult.fail(
        q == null ? 'La file de lecture est vide.' : 'Aucun résultat pour « $q ».',
      );
    }
    await ctx.ref
        .read(namedQueuesProvider.notifier)
        .createFromSongs(name, songs);
    final word = songs.length > 1 ? 'morceaux' : 'morceau';
    if (optBool(args, 'shuffled')) {
      final service = ctx.ref.read(audioPlayerServiceProvider);
      await service.playSong(songs.first, queue: songs, index: 0);
      if (!service.isShuffleEnabled) await service.toggleShuffle();
      return AiToolResult.ok(
        'File « $name » créée (${songs.length} $word), lecture en aléatoire.',
      );
    }
    return AiToolResult.ok(
      'File « $name » créée (${songs.length} $word).',
    );
  }
}
