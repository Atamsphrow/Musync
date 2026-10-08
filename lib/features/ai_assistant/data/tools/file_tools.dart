/// Outils de fichiers : modification de tags, suppression, correction depuis
/// le nom de fichier.
///
/// Ce sont les outils destructeurs : [requiresConfirmation] est toujours
/// vrai, un fichier à la fois, et l'écriture suit le même protocole que
/// l'éditeur de tags — autorisation système, travail sur une copie dans le
/// cache, remplacement atomique, rescan MediaStore. L'original n'est jamais
/// laissé à moitié écrit.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/tag_metadata.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';

/// Écrit des tags en suivant le protocole sécurisé de l'éditeur de tags.
///
/// 1. Autorisation d'écriture système (Android 11+) ; un refus annule tout.
/// 2. Copie de travail dans le cache — l'original n'est jamais ouvert.
/// 3. Écriture dans la copie.
/// 4. Copie binaire sur l'original via un temp frère + rename atomique.
/// 5. Rescan MediaStore.
///
/// Rend un message d'échec en français, jamais d'exception.
Future<AiToolResult> _writeTagsSecurely(
  Ref ref,
  Song song,
  TrackMetadata metadata,
) async {
  final granted = await MediaStore.requestWriteAccess(
    mediaStoreId: song.id,
    path: song.filePath,
  );
  if (!granted) {
    return AiToolResult.fail('Écriture refusée par le système.');
  }
  try {
    final cacheDir = await getTemporaryDirectory();
    final workPath = p.join(cacheDir.path, 'ai_tag_${song.id}.tmp');
    final workFile = File(workPath);
    if (await workFile.exists()) await workFile.delete();
    await File(song.filePath).copy(workPath);

    try {
      await Id3Writer.writeMetadata(workPath, metadata);
    } on Id3WriteException catch (e) {
      if (await workFile.exists()) await workFile.delete();
      return AiToolResult.fail(e.message);
    }

    final target = File(song.filePath);
    final stage = File('${target.path}.musync.tmp');
    if (await stage.exists()) await stage.delete();
    await workFile.copy(stage.path);
    if (await workFile.exists()) await workFile.delete();
    await stage.rename(target.path);

    await MediaStore.rescan(target.path);
  } catch (_) {
    return AiToolResult.fail('Écriture impossible — fichier intact.');
  }

  // Le morceau en cours garde ses tags affichés à jour.
  final service = ref.read(audioPlayerServiceProvider);
  if (service.currentSong?.id == song.id) {
    service.updateCurrentSongMetadata(
      title: metadata.title ?? song.title,
      artist: metadata.artist ?? song.artist,
      album: metadata.album ?? song.album,
    );
  }
  ref.invalidate(currentLyricsProvider);
  return AiToolResult.ok('Tags mis à jour pour ${songLabel(song)}.');
}

/// Résout le morceau visé : par requête, ou le morceau en cours.
///
/// Refuse quand la requête matche plusieurs morceaux : les outils de
/// fichiers traitent un fichier à la fois.
Future<Song?> _resolveSingleTarget(
  AiToolContext ctx,
  String? query,
) async {
  if (query != null) {
    final matches = matchSongs(await librarySongs(ctx.ref), query);
    if (matches.isEmpty) return null;
    if (matches.length > 1) {
      throw AiToolArgError(
        '« $query » correspond à ${matches.length} morceaux — précisez.',
      );
    }
    return matches.first;
  }
  return ctx.ref.read(audioPlayerServiceProvider).currentSong;
}

/// Modifie les tags du morceau (un fichier à la fois, confirmation).
class EditTagsTool extends AiTool {
  const EditTagsTool();

  @override
  String get name => 'edit_tags';

  @override
  String get description =>
      'Modifie les tags du morceau en cours (ou de "query") : titre, '
      'artiste, album. Un seul champ suffit. Écriture sécurisée '
      '(copie + remplacement atomique).';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'title': 'string, optionnel — nouveau titre',
          'artist': 'string, optionnel — nouvel artiste',
          'album': 'string, optionnel — nouvel album',
          'query':
              'string, optionnel — morceau visé ; sinon le morceau en cours',
        },
      };

  @override
  bool get requiresConfirmation => true;

  TrackMetadata _diff(Map<String, Object?> args) {
    final title = optString(args, 'title');
    final artist = optString(args, 'artist');
    final album = optString(args, 'album');
    if (title == null && artist == null && album == null) {
      throw const AiToolArgError(
        'Précisez au moins title, artist ou album.',
      );
    }
    return (
      title: title,
      artist: artist,
      album: album,
      albumArtist: null,
      genre: null,
      year: null,
      trackNumber: null,
      trackTotal: null,
      discNumber: null,
      discTotal: null,
      composer: null,
      comment: null,
      artwork: null,
    );
  }

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final target =
        await _resolveSingleTarget(ctx, optString(args, 'query'));
    if (target == null) return 'Morceau introuvable.';
    final lines = <String>[
      'Modifier les tags de ${songLabel(target)} :',
    ];
    final title = optString(args, 'title');
    final artist = optString(args, 'artist');
    final album = optString(args, 'album');
    if (title != null) lines.add('  titre : « ${target.title} » → « $title »');
    if (artist != null) {
      lines.add('  artiste : « ${target.artist} » → « $artist »');
    }
    if (album != null) lines.add('  album : « ${target.album} » → « $album »');
    return lines.join('\n');
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final metadata = _diff(args);
    final target =
        await _resolveSingleTarget(ctx, optString(args, 'query'));
    if (target == null) {
      return AiToolResult.fail('Morceau introuvable.');
    }
    return _writeTagsSecurely(ctx.ref, target, metadata);
  }
}

/// Supprime le fichier du morceau (un seul, confirmation obligatoire).
class DeleteFileTool extends AiTool {
  const DeleteFileTool();

  @override
  String get name => 'delete_file';

  @override
  String get description =>
      'Supprime définitivement le fichier audio du morceau en cours (ou de '
      '"query"). Un seul fichier à la fois ; la lecture s’arrête avant.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'query':
              'string, optionnel — morceau visé ; sinon le morceau en cours',
        },
      };

  @override
  bool get requiresConfirmation => true;

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final target =
        await _resolveSingleTarget(ctx, optString(args, 'query'));
    if (target == null) return 'Morceau introuvable.';
    return 'Supprimer DÉFINITIVEMENT le fichier :\n'
        '${target.filePath}\n'
        '${songLabel(target)}';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final target =
        await _resolveSingleTarget(ctx, optString(args, 'query'));
    if (target == null) {
      return AiToolResult.fail('Morceau introuvable.');
    }
    final service = ctx.ref.read(audioPlayerServiceProvider);
    try {
      // Ne jamais supprimer le fichier sous le lecteur : avancer d'abord.
      if (service.currentSong?.id == target.id) {
        if (service.queue.length > 1) {
          await service.next();
        } else {
          await service.stop();
        }
      }
      final index =
          service.queue.indexWhere((s) => s.id == target.id);
      if (index >= 0) await service.removeFromQueue(index);

      final file = File(target.filePath);
      if (await file.exists()) await file.delete();
      await MediaStore.rescan(target.filePath);
    } catch (_) {
      return AiToolResult.fail(
        'Suppression impossible pour ${songLabel(target)}.',
      );
    }
    ctx.ref.invalidate(songListProvider);
    return AiToolResult.ok('${songLabel(target)} supprimé.');
  }
}

/// Corrige artiste/titre depuis le nom du fichier, via l'IA des Paramètres.
///
/// D'abord une analyse locale du nom (gratuite, instantanée) ; l'IA des
/// Paramètres n'est appelée que pour les noms que l'analyse ne tranche pas.
/// La confirmation montre chaque changement avant écriture.
class FixTagsFromFilenameTool extends AiTool {
  const FixTagsFromFilenameTool();

  @override
  String get name => 'fix_tags_from_filename';

  @override
  String get description =>
      'Corrige l’artiste et le titre depuis le nom du fichier '
      '(« Artiste - Titre.mp3 »), via l’IA configurée dans les '
      'Paramètres IA. Un morceau ("query") ou le morceau en cours.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'query':
              'string, optionnel — morceau visé ; sinon le morceau en cours',
        },
      };

  @override
  bool get requiresConfirmation => true;

  /// Les changements prévus, en lecture seule : le dialogue de confirmation
  /// montre exactement ce qui sera écrit.
  Future<List<({Song song, FilenameGuess guess})>> _planned(
    AiToolContext ctx,
    String? query,
  ) async {
    final target = await _resolveSingleTarget(ctx, query);
    if (target == null) return const [];
    final settings =
        await ctx.ref.read(aiSettingsStoreProvider).load();
    if (settings.usable.isEmpty) {
      throw const AiToolArgError(
        'Aucune clé IA configurée (Paramètres IA).',
      );
    }
    final resolver = ctx.ref.read(aiFilenameResolverProvider);
    final resolution = await resolver.resolve(
      settings: settings,
      fileName: p.basename(target.filePath),
    );
    final guess = resolution.guess;
    if (guess == null ||
        (guess.artist.isEmpty && guess.title.isEmpty)) {
      return const [];
    }
    return [(song: target, guess: guess)];
  }

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final planned = await _planned(ctx, optString(args, 'query'));
    if (planned.isEmpty) {
      return 'Aucune correction proposée (nom de fichier illisible).';
    }
    final lines = <String>['Corriger les tags depuis le nom de fichier :'];
    for (final item in planned) {
      lines.add(
        '  ${songLabel(item.song)}\n'
        '    → ${item.guess.artist} — ${item.guess.title}',
      );
    }
    return lines.join('\n');
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final planned = await _planned(ctx, optString(args, 'query'));
    if (planned.isEmpty) {
      return AiToolResult.fail(
        'Aucune correction proposée (nom de fichier illisible).',
      );
    }
    for (final item in planned) {
      final metadata = (
        title: item.guess.title.isEmpty ? null : item.guess.title,
        artist: item.guess.artist.isEmpty ? null : item.guess.artist,
        album: null,
        albumArtist: null,
        genre: null,
        year: null,
        trackNumber: null,
        trackTotal: null,
        discNumber: null,
        discTotal: null,
        composer: null,
        comment: null,
        artwork: null,
      );
      final result = await _writeTagsSecurely(ctx.ref, item.song, metadata);
      if (!result.ok) return result;
    }
    final first = planned.first;
    return AiToolResult.ok(
      'Tags corrigés : ${first.guess.artist} — ${first.guess.title}.',
    );
  }
}
