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
import 'dart:typed_data';

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
      'artiste, album, genre, année. Un seul champ suffit. Écriture sécurisée '
      '(copie + remplacement atomique).';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'title': 'string, optionnel — nouveau titre',
          'artist': 'string, optionnel — nouvel artiste',
          'album': 'string, optionnel — nouvel album',
          'genre': 'string, optionnel — nouveau genre',
          'year': 'string, optionnel — nouvelle année (ex. "2024")',
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
    final genre = optString(args, 'genre');
    final year = optString(args, 'year');
    if (title == null &&
        artist == null &&
        album == null &&
        genre == null &&
        year == null) {
      throw const AiToolArgError(
        'Précisez au moins title, artist, album, genre ou year.',
      );
    }
    return (
      title: title,
      artist: artist,
      album: album,
      albumArtist: null,
      genre: genre,
      year: year,
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
    final query = optString(args, 'query');
    final target = await _resolveSingleTarget(ctx, query);
    if (target == null) {
      throw AiToolArgError(
        'Morceau introuvable${query == null ? '' : ' : « $query »'}.',
      );
    }
    final lines = <String>[
      'Modifier les tags de ${songLabel(target)} :',
    ];
    final title = optString(args, 'title');
    final artist = optString(args, 'artist');
    final album = optString(args, 'album');
    final genre = optString(args, 'genre');
    final year = optString(args, 'year');
    if (title != null) lines.add('  titre : « ${target.title} » → « $title »');
    if (artist != null) {
      lines.add('  artiste : « ${target.artist} » → « $artist »');
    }
    if (album != null) lines.add('  album : « ${target.album} » → « $album »');
    if (genre != null) lines.add('  genre → « $genre »');
    if (year != null) lines.add('  année → « $year »');
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
    final query = optString(args, 'query');
    final target = await _resolveSingleTarget(ctx, query);
    if (target == null) {
      throw AiToolArgError(
        'Morceau introuvable${query == null ? '' : ' : « $query »'}.',
      );
    }
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
    if (target == null) {
      throw AiToolArgError(
        'Morceau introuvable${query == null ? '' : ' : « $query »'}.',
      );
    }
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

/// Nom de fichier sûr à partir d'un texte : les caractères interdits par les
/// systèmes de fichiers deviennent des underscores, les espaces sont tassés.
String _safeFileName(String raw) {
  var out = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  out = out.replaceAll(RegExp(r'\s+'), ' ');
  if (out.isEmpty) return '_';
  // Windows refuse les noms qui finissent par un point ou un espace.
  out = out.replaceAll(RegExp(r'[. ]+$'), '');
  return out.isEmpty ? '_' : out;
}

/// Renomme les fichiers audio d'après leurs tags.
///
/// Motif « Artiste - Titre » par défaut, « Titre - Artiste » sur demande.
/// Un fichier à la fois dans l'esprit, mais en lot borné à la bibliothèque
/// filtrée : la confirmation montre l'aperçu avant. Non annulable depuis
/// l'Historique (ce n'est pas une écriture de tags).
class BatchRenameFilesTool extends AiTool {
  const BatchRenameFilesTool();

  @override
  String get name => 'batch_rename_files';

  @override
  String get description =>
      'Renomme les fichiers audio d’après leurs tags : '
      '« Artiste - Titre.mp3 » (ou « Titre - Artiste.mp3 » avec '
      'pattern="title-artist"). Les caractères interdits sont remplacés. '
      'Non annulable depuis l’Historique.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'pattern':
              'string, optionnel — "artist-title" (défaut) ou "title-artist"',
          'query':
              'string, optionnel — restreint aux morceaux correspondants ; sinon toute la bibliothèque',
        },
      };

  @override
  bool get requiresConfirmation => true;

  Future<List<Song>> _targets(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final songs = await librarySongs(ctx.ref);
    final query = optString(args, 'query');
    return query == null ? songs : matchSongs(songs, query);
  }

  String _newName(Song song, String pattern) {
    final title = song.title.trim();
    if (title.isEmpty) return '';
    final artist = song.artist.trim();
    final base = pattern == 'title-artist'
        ? (artist.isEmpty ? title : '$title - $artist')
        : (artist.isEmpty ? title : '$artist - $title');
    return '${_safeFileName(base)}${p.extension(song.filePath)}';
  }

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final songs = await _targets(ctx, args);
    if (songs.isEmpty) {
      throw const AiToolArgError('Aucun morceau correspondant.');
    }
    final pattern = optString(args, 'pattern') ?? 'artist-title';
    final preview = songs.take(3).map((s) {
      final name = _newName(s, pattern);
      return '  ${p.basename(s.filePath)} → ${name.isEmpty ? '(titre vide, ignoré)' : name}';
    }).join('\n');
    return 'Renommer ${songs.length} fichiers '
        '(motif « ${pattern == 'title-artist' ? 'Titre - Artiste' : 'Artiste - Titre'} ») :\n'
        '$preview${songs.length > 3 ? '\n  …' : ''}';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final songs = await _targets(ctx, args);
    if (songs.isEmpty) {
      return AiToolResult.fail('Aucun morceau correspondant.');
    }
    final pattern = optString(args, 'pattern') ?? 'artist-title';
    var renamed = 0;
    var skipped = 0;
    for (final song in songs) {
      final name = _newName(song, pattern);
      if (name.isEmpty || name == p.basename(song.filePath)) {
        skipped++;
        continue;
      }
      final target = p.join(p.dirname(song.filePath), name);
      try {
        if (await File(target).exists()) {
          skipped++;
          continue;
        }
        await File(song.filePath).rename(target);
        await MediaStore.rescan(target);
        renamed++;
      } catch (_) {
        skipped++;
      }
    }
    ctx.ref.invalidate(songListProvider);
    return AiToolResult.ok(
      '$renamed fichier${renamed > 1 ? 's' : ''} renommé${renamed > 1 ? 's' : ''}'
      '${skipped > 0 ? ' ($skipped ignoré${skipped > 1 ? 's' : ''})' : ''}.',
    );
  }
}

/// Change la pochette du morceau depuis un fichier image.
///
/// Même protocole sécurisé que l'éditeur : autorisation système, travail sur
/// une copie, remplacement atomique. Confirmation exigée.
class ChangeCoverTool extends AiTool {
  const ChangeCoverTool();

  @override
  String get name => 'change_cover';

  @override
  String get description =>
      'Change la pochette du morceau en cours (ou de "query") depuis un '
      'fichier image (chemin complet). Écriture sécurisée comme l’éditeur '
      'de tags.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'image': 'string, requis — chemin complet du fichier image',
          'query':
              'string, optionnel — morceau visé ; sinon le morceau en cours',
        },
      };

  @override
  bool get requiresConfirmation => true;

  static bool _looksLikeImage(List<int> bytes) {
    if (bytes.length < 4) return false;
    // JPEG, PNG, GIF, WebP, BMP.
    return (bytes[0] == 0xFF && bytes[1] == 0xD8) ||
        (bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4E &&
            bytes[3] == 0x47) ||
        (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) ||
        (bytes[0] == 0x52 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x46) ||
        (bytes[0] == 0x42 && bytes[1] == 0x4D);
  }

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final query = optString(args, 'query');
    final target = await _resolveSingleTarget(ctx, query);
    if (target == null) {
      throw AiToolArgError(
        'Morceau introuvable${query == null ? '' : ' : « $query »'}.',
      );
    }
    final image = reqString(args, 'image');
    return 'Changer la pochette de ${songLabel(target)} '
        'avec l’image :\n$image';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final target = await _resolveSingleTarget(ctx, optString(args, 'query'));
    if (target == null) {
      return AiToolResult.fail('Morceau introuvable.');
    }
    final imagePath = reqString(args, 'image');
    Uint8List bytes;
    try {
      bytes = await File(imagePath).readAsBytes();
    } catch (_) {
      return AiToolResult.fail('Image introuvable : $imagePath');
    }
    if (bytes.isEmpty || !_looksLikeImage(bytes)) {
      return AiToolResult.fail('Ce fichier n’est pas une image reconnue.');
    }
    final result = await _writeTagsSecurely(
      ctx.ref,
      target,
      (
        title: null,
        artist: null,
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
        artwork: bytes,
      ),
    );
    if (!result.ok) return result;
    await ctx.ref.read(audioPlayerServiceProvider).forgetArtwork(target);
    return AiToolResult.ok(
      'Pochette mise à jour pour ${songLabel(target)}.',
    );
  }
}

/// Déplace des fichiers audio vers un dossier.
///
/// Le morceau en cours par défaut (ou "query"), ou toute la bibliothèque
/// avec all=true. Le dossier est créé s'il n'existe pas. Non annulable
/// depuis l'Historique.
class MoveSongsTool extends AiTool {
  const MoveSongsTool();

  @override
  String get name => 'move_songs';

  @override
  String get description =>
      'Déplace le fichier du morceau en cours (ou de "query", ou toute la '
      'bibliothèque avec all=true) vers un dossier, créé s’il n’existe pas. '
      'Non annulable depuis l’Historique.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'folder': 'string, requis — dossier de destination',
          'query':
              'string, optionnel — morceau visé ; sinon le morceau en cours',
          'all': 'booléen, optionnel — toute la bibliothèque',
        },
      };

  @override
  bool get requiresConfirmation => true;

  Future<List<Song>> _targets(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final query = optString(args, 'query');
    if (query != null) {
      final matches = matchSongs(await librarySongs(ctx.ref), query);
      if (matches.isEmpty) return const [];
      if (matches.length > 1) {
        throw AiToolArgError(
          '« $query » correspond à ${matches.length} morceaux — précisez.',
        );
      }
      return matches;
    }
    if (optBool(args, 'all')) return librarySongs(ctx.ref);
    final song = ctx.ref.read(audioPlayerServiceProvider).currentSong;
    return song == null ? const [] : [song];
  }

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final folder = reqString(args, 'folder');
    final songs = await _targets(ctx, args);
    if (songs.isEmpty) {
      throw const AiToolArgError('Aucun morceau visé.');
    }
    if (songs.length == 1) {
      return 'Déplacer ${songLabel(songs.first)} vers :\n$folder';
    }
    return 'Déplacer ${songs.length} morceaux vers :\n$folder';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final folder = reqString(args, 'folder');
    final dir = Directory(folder);
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (_) {
      return AiToolResult.fail('Dossier inaccessible : $folder');
    }
    final songs = await _targets(ctx, args);
    if (songs.isEmpty) {
      return AiToolResult.fail('Aucun morceau visé.');
    }
    var moved = 0;
    var skipped = 0;
    for (final song in songs) {
      final target = p.join(dir.path, p.basename(song.filePath));
      if (target == song.filePath) {
        skipped++;
        continue;
      }
      try {
        if (await File(target).exists()) {
          skipped++;
          continue;
        }
        await File(song.filePath).rename(target);
        await MediaStore.rescan(target);
        moved++;
      } catch (_) {
        skipped++;
      }
    }
    ctx.ref.invalidate(songListProvider);
    return AiToolResult.ok(
      '$moved fichier${moved > 1 ? 's' : ''} déplacé${moved > 1 ? 's' : ''} vers $folder'
      '${skipped > 0 ? ' ($skipped ignoré${skipped > 1 ? 's' : ''})' : ''}.',
    );
  }
}
