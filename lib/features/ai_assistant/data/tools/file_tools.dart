/// Outils de fichiers : modification de tags, suppression, correction depuis
/// le nom de fichier.
///
/// Ce sont les outils destructeurs : [requiresConfirmation] est toujours
/// vrai, un fichier à la fois, et l'écriture suit le même protocole que
/// l'éditeur de tags — autorisation système, travail sur une copie dans le
/// cache, remplacement atomique, rescan MediaStore. L'original n'est jamais
/// laissé à moitié écrit.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/tag_metadata.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/tools/library_path_guard.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';

/// Verify a copied file byte-for-byte before removing its source or
/// replacing the original. Reads bounded chunks; storage exhaustion and
/// partial copies cause a failed operation, not a broken music file.
Future<bool> _sameFileBytes(File a, File b) async {
  if (await a.length() != await b.length()) return false;
  final first = await a.open(mode: FileMode.read);
  try {
    final second = await b.open(mode: FileMode.read);
    try {
      while (true) {
        final left = await first.read(256 * 1024);
        final right = await second.read(256 * 1024);
        if (left.length != right.length) return false;
        if (left.isEmpty) return true;
        for (var i = 0; i < left.length; i++) {
          if (left[i] != right[i]) return false;
        }
      }
    } finally {
      await second.close();
    }
  } finally {
    await first.close();
  }
}

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
  // Suffixe unique par exécution : deux écritures concurrentes sur le même
  // morceau ne partagent plus leurs fichiers temporaires.
  final stamp = DateTime.now().microsecondsSinceEpoch;
  File? workFile;
  File? stage;
  try {
    final cacheDir = await getTemporaryDirectory();
    final workPath = p.join(cacheDir.path, 'ai_tag_${song.id}_$stamp.tmp');
    workFile = File(workPath);
    if (await workFile.exists()) await workFile.delete();
    await File(song.filePath).copy(workPath);

    try {
      await Id3Writer.writeMetadata(workPath, metadata);
    } on Id3WriteException catch (e) {
      return AiToolResult.fail(e.message);
    }

    final target = File(song.filePath);
    stage = File('${target.path}.musync.$stamp.tmp');
    if (await stage.exists()) await stage.delete();
    await workFile.copy(stage.path);
    if (!await _sameFileBytes(workFile, stage)) {
      return AiToolResult.fail('Copie incomplète : fichier original préservé.');
    }
    await stage.rename(target.path);

    await MediaStore.rescan(target.path);
  } catch (e) {
    DebugLog.instance.warning(
      'OutilsFichiers',
      'Écriture des tags impossible pour ${song.filePath}',
      error: e,
    );
    return AiToolResult.fail('Écriture impossible — fichier intact.');
  } finally {
    // Tout échec (écriture, copie, rename) laissait sinon un .tmp orphelin
    // dans le cache ou à côté du morceau. Après succès les deux ont déjà
    // disparu (copie supprimée, stage renommé) : le nettoyage est un no-op.
    for (final f in [workFile, stage]) {
      try {
        if (f != null && await f.exists()) await f.delete();
      } catch (_) {}
    }
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
  // La liste aussi : titre/artiste/album affichés venaient de l'ancienne
  // lecture, le morceau retaggué restait affiché tel quel jusqu'au prochain
  // rafraîchissement.
  ref.invalidate(songListProvider);
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

/// Cible figée au moment de la confirmation.
///
/// [describeAction] résout les cibles et les fige ici ; [execute] reprend
/// exactement ces cibles et ne re-résout plus depuis l'état courant. Sans ça,
/// une action destructive (suppression, tags, pochette, déplacement, renommage
/// en lot) pouvait porter sur un autre fichier que celui confirmé : le morceau
/// en cours ou la bibliothèque peuvent changer entre l'aperçu et le « Confirmer ».
///
/// Le snapshot voyage dans [args] sous [_snapshotKey] : c'est la même Map qui
/// traverse [AssistantNeedsConfirmation] jusqu'à `runConfirmed`, donc aucune
/// autre pièce n'a besoin de changer. [Song] est immuable : figer l'objet fige
/// aussi son chemin. Pour `fix_tags_from_filename`, la correction proposée
/// ([FilenameGuess]) est figée avec le morceau, sinon `execute` rappellerait
/// l'IA et pourrait écrire une autre correction que celle montrée.
typedef _ConfirmedTarget = ({Song song, FilenameGuess? guess});

/// Clé interne du snapshot — jamais un argument du modèle, ajoutée par
/// [describeAction] après la validation stricte des arguments.
const _snapshotKey = '__musync_confirmed_targets';

/// Dernier snapshot connu par outil, quand [args] refuse l'écriture : le
/// contrôleur passe `const {}` quand le modèle omet « args », et écrire dans
/// une Map constante lèverait. [execute] y puise alors, au lieu d'échouer ou
/// de re-résoudre. Écrasé à chaque [describeAction], un seul dialogue de
/// confirmation ne pouvant être ouvert à la fois.
final Map<String, List<_ConfirmedTarget>> _fallbackTargets = {};

// The preview must also freeze the destination / cover path. Without this a
// mutable args map could be edited after a user confirms one path.
const _confirmedPathKey = '_musync_confirmed_path';
final Map<String, String> _fallbackConfirmedPaths = {};

void _freezeConfirmedPath(
  Map<String, Object?> args,
  String toolName,
  String path,
) {
  try {
    args[_confirmedPathKey] = path;
    _fallbackConfirmedPaths.remove(toolName);
  } on UnsupportedError {
    _fallbackConfirmedPaths[toolName] = path;
  }
}

String? _consumeConfirmedPath(Map<String, Object?> args, String toolName) {
  final raw = args[_confirmedPathKey];
  try {
    if (raw != null) args.remove(_confirmedPathKey);
  } on UnsupportedError {
    // Immutable argument maps use the fallback snapshot instead.
  }
  if (raw is String) return raw;
  return _fallbackConfirmedPaths.remove(toolName);
}

void _freezeTargets(
  Map<String, Object?> args,
  String toolName,
  List<_ConfirmedTarget> targets,
) {
  final frozen = List<_ConfirmedTarget>.unmodifiable(targets);
  try {
    args[_snapshotKey] = frozen;
    // Un snapshot précédent en repli ne doit pas survivre : il daterait
    // d'une confirmation annulée.
    _fallbackTargets.remove(toolName);
  } on UnsupportedError {
    _fallbackTargets[toolName] = frozen;
  }
}

/// Les cibles confirmées, ou null si [describeAction] n'a pas tourné avant
/// (appel direct d'[execute], sans confirmation : on re-résout alors comme
/// avant, faute de cible confirmée à honorer).
List<_ConfirmedTarget>? _confirmedTargets(
  Map<String, Object?> args,
  String toolName,
) {
  final raw = args[_snapshotKey];
  if (raw is List<_ConfirmedTarget>) return List.of(raw);
  // Repli consommé d'un coup : un snapshot ne sert qu'à l'exécution qui suit
  // sa confirmation, jamais à un appel ultérieur sans describe.
  final fallback = _fallbackTargets.remove(toolName);
  return fallback == null ? null : List.of(fallback);
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
    // Valide d'abord : sans champ à modifier, le dialogue confirmerait une
    // écriture qui ne change rien — le contrôle n'avait lieu que dans
    // `execute`, après la confirmation.
    _diff(args);
    final query = optString(args, 'query');
    final target = await _resolveSingleTarget(ctx, query);
    if (target == null) {
      throw AiToolArgError(
        'Morceau introuvable${query == null ? '' : ' : « $query »'}.',
      );
    }
    // Fige la cible confirmée : execute ne re-résoudra pas.
    _freezeTargets(args, name, [(song: target, guess: null)]);
    final lines = <String>[
      'Modifier les tags de ${_forPreview(songLabel(target))} :',
    ];
    final title = optString(args, 'title');
    final artist = optString(args, 'artist');
    final album = optString(args, 'album');
    final genre = optString(args, 'genre');
    final year = optString(args, 'year');
    if (title != null) {
      lines.add(
        '  titre : « ${_forPreview(target.title)} » → « ${_forPreview(title)} »',
      );
    }
    if (artist != null) {
      lines.add(
        '  artiste : « ${_forPreview(target.artist)} » → « ${_forPreview(artist)} »',
      );
    }
    if (album != null) {
      lines.add(
        '  album : « ${_forPreview(target.album)} » → « ${_forPreview(album)} »',
      );
    }
    if (genre != null) lines.add('  genre → « ${_forPreview(genre)} »');
    if (year != null) lines.add('  année → « ${_forPreview(year)} »');
    return lines.join('\n');
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final metadata = _diff(args);
    // Cible confirmée par describeAction ; sans elle (appel direct),
    // résolution comme avant.
    final confirmed = _confirmedTargets(args, name);
    final target = confirmed != null && confirmed.isNotEmpty
        ? confirmed.first.song
        : await _resolveSingleTarget(ctx, optString(args, 'query'));
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
    // Fige la cible confirmée : execute ne re-résoudra pas.
    _freezeTargets(args, name, [(song: target, guess: null)]);
    return 'Supprimer DÉFINITIVEMENT le fichier :\n'
        '${_forPreview(target.filePath)}\n'
        '${_forPreview(songLabel(target))}';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    // Cible confirmée par describeAction ; sans elle (appel direct),
    // résolution comme avant.
    final confirmed = _confirmedTargets(args, name);
    final target = confirmed != null && confirmed.isNotEmpty
        ? confirmed.first.song
        : await _resolveSingleTarget(ctx, optString(args, 'query'));
    if (target == null) {
      return AiToolResult.fail('Morceau introuvable.');
    }
    // Sans l'accès « Tous les fichiers », la suppression d'un fichier de la
    // bibliothèque partagée échoue côté système : le vérifier d'abord donne
    // un message actionnable au lieu d'un échec générique après coup.
    // (Hors Android, `hasWriteAccess` rend vrai sans appel natif.)
    if (!await PermissionService.hasWriteAccess()) {
      return AiToolResult.fail(
        'Suppression impossible : accordez l’accès « Tous les fichiers » '
        'à Musync dans les paramètres Android.',
      );
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
  ///
  /// Avec [confirmed] (cibles figées par [describeAction]), reprend le
  /// morceau ET la correction proposée sans re-résoudre ni rappeler l'IA :
  /// la correction exécutée est celle qui a été montrée.
  Future<List<({Song song, FilenameGuess guess})>> _planned(
    AiToolContext ctx,
    String? query, {
    List<_ConfirmedTarget>? confirmed,
  }) async {
    if (confirmed != null) {
      return [
        for (final target in confirmed)
          if (target.guess != null)
            (song: target.song, guess: target.guess!),
      ];
    }
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
    // Fige morceau + correction proposée : execute ne re-résoudra pas et ne
    // rappellera pas l'IA.
    _freezeTargets(args, name, [
      for (final item in planned)
        (song: item.song, guess: item.guess),
    ]);
    if (planned.isEmpty) {
      return 'Aucune correction proposée (nom de fichier illisible).';
    }
    final lines = <String>['Corriger les tags depuis le nom de fichier :'];
    for (final item in planned) {
      lines.add(
        '  ${_forPreview(songLabel(item.song))}\n'
        '    → ${_forPreview(item.guess.artist)} — ${_forPreview(item.guess.title)}',
      );
    }
    return lines.join('\n');
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    // Cibles confirmées par describeAction (morceau + correction) ; sans
    // elles (appel direct), planification comme avant.
    final confirmed = _confirmedTargets(args, name);
    final planned = await _planned(
      ctx,
      optString(args, 'query'),
      confirmed: confirmed,
    );
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

/// Valeur telle qu'elle apparaît dans un aperçu de confirmation.
///
/// Les chemins et valeurs viennent des tags ou des arguments du modèle : un
/// `\n` ou un caractère de contrôle dans un nom de fichier falsifierait
/// l'aperçu (fausse ligne, fausse cible). Contrôles neutralisés, longueur
/// bornée — l'aperçu reste lisible sans jamais réécrire le texte.
String _forPreview(String value) {
  var out = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
  if (out.length > 200) out = '${out.substring(0, 199)}…';
  return out;
}

/// Nom de fichier sûr à partir d'un texte : les caractères interdits par les
/// systèmes de fichiers deviennent des underscores, les espaces sont tassés.
String _safeFileName(String raw) {
  // NUL et caractères de contrôle : interdits partout, et un NUL ferait
  // échouer le rename sans explication.
  var out = raw.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '_');
  out = out.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  out = out.replaceAll(RegExp(r'\s+'), ' ');
  if (out.isEmpty) return '_';
  // Windows refuse les noms qui finissent par un point ou un espace.
  out = out.replaceAll(RegExp(r'[. ]+$'), '');
  if (out.isEmpty) return '_';
  // 255 octets par nom sur ext4 : 200 octets laissent de la marge pour
  // l'extension ajoutée ensuite, même en multi-octets.
  while (utf8.encode(out).length > 200) {
    out = out.substring(0, out.length - 1).replaceAll(RegExp(r'[. ]+$'), '');
    if (out.isEmpty) return '_';
  }
  return out;
}

/// Motifs de renommage acceptés. Toute autre valeur est rejetée d'emblée :
/// l'ancien repli silencieux vers « artist-title » affichait « Artiste -
/// Titre » pour une faute de frappe ou une valeur inventée par le modèle.
String _validatedPattern(Map<String, Object?> args) {
  final pattern = optString(args, 'pattern') ?? 'artist-title';
  if (pattern != 'artist-title' && pattern != 'title-artist') {
    throw AiToolArgError(
      'Motif inconnu : « $pattern » (artist-title ou title-artist).',
    );
  }
  return pattern;
}

/// Déplace un fichier, avec repli copie + suppression quand le rename direct
/// échoue (EXDEV : volumes différents — carte SD, OTG…). Rend `true` si le
/// fichier est arrivé à destination, `false` sinon ; une copie partielle est
/// nettoyée, et la source n'est jamais supprimée sans copie réussie.
Future<bool> _moveFile(File source, String target) async {
  try {
    await source.rename(target);
    return true;
  } on FileSystemException {
    // rename ne traverse pas les volumes : copie puis suppression.
    try {
      final copy = await source.copy(target);
      if (!await _sameFileBytes(source, copy)) {
        throw const FileSystemException('Copie incomplète : source conservée');
      }
      await source.delete();
      return true;
    } catch (e) {
      DebugLog.instance.warning(
        'OutilsFichiers',
        'Déplacement impossible pour ${source.path}',
        error: e,
      );
      try {
        final partial = File(target);
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return false;
    }
  }
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
    // Fige la liste confirmée : execute ne relira pas la bibliothèque.
    _freezeTargets(args, name, [
      for (final song in songs) (song: song, guess: null),
    ]);
    final pattern = _validatedPattern(args);
    final preview = songs.take(3).map((s) {
      final name = _newName(s, pattern);
      return '  ${_forPreview(p.basename(s.filePath))} → ${name.isEmpty ? '(titre vide, ignoré)' : _forPreview(name)}';
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
    // Liste confirmée par describeAction ; sans elle (appel direct),
    // résolution comme avant.
    final confirmed = _confirmedTargets(args, name);
    final songs = confirmed == null
        ? await _targets(ctx, args)
        : [for (final target in confirmed) target.song];
    if (songs.isEmpty) {
      return AiToolResult.fail('Aucun morceau correspondant.');
    }
    final pattern = _validatedPattern(args);
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
        // Fenêtre TOCTOU résiduelle : un autre processus peut créer la
        // cible entre ce test et le rename, qui l'écraserait alors. Dart
        // n'offre pas de rename-if-absent (il faudrait renameat2
        // RENAME_NOREPLACE, natif) ; le test couvre le cas réaliste — deux
        // renommages concurrents du même morceau dans l'app.
        if (await File(target).exists()) {
          skipped++;
          continue;
        }
        if (await _moveFile(File(song.filePath), target)) {
          // Chemin mis à jour avant le rescan : même si celui-ci lève, le
          // lecteur ne pointe plus vers l'ancien chemin.
          ctx.ref
              .read(audioPlayerServiceProvider)
              .updateSongPath(song.filePath, target);
          await MediaStore.rescan(target);
          renamed++;
        } else {
          skipped++;
        }
      } catch (e) {
        DebugLog.instance.warning(
          'OutilsFichiers',
          'Renommage impossible pour ${song.filePath}',
          error: e,
        );
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
    // JPEG, PNG, GIF.
    if ((bytes[0] == 0xFF && bytes[1] == 0xD8) ||
        (bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4E &&
            bytes[3] == 0x47) ||
        (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46)) {
      return true;
    }
    // WebP : RIFF + taille (4 octets) + « WEBP » à l'offset 8 — un RIFF
    // seul peut être un WAV ou un AVI.
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    // BMP : 2 octets, c'est la signature complète du format.
    return bytes[0] == 0x42 && bytes[1] == 0x4D;
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
    // Fige la cible confirmée : execute ne re-résoudra pas.
    _freezeTargets(args, name, [(song: target, guess: null)]);
    final image = reqString(args, 'image');
    if (!await LibraryPathGuard.permits(
      image, (await librarySongs(ctx.ref)).map((song) => song.filePath),
    )) {
      throw const AiToolArgError(
        'Image hors des dossiers de la bibliothèque ou chemin non sûr.',
      );
    }
    _freezeConfirmedPath(args, name, image);
    return 'Changer la pochette de ${_forPreview(songLabel(target))} '
        'avec l’image :\n${_forPreview(image)}';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    // Cible confirmée par describeAction ; sans elle (appel direct),
    // résolution comme avant.
    final confirmed = _confirmedTargets(args, name);
    final target = confirmed != null && confirmed.isNotEmpty
        ? confirmed.first.song
        : await _resolveSingleTarget(ctx, optString(args, 'query'));
    if (target == null) {
      return AiToolResult.fail('Morceau introuvable.');
    }
    final imagePath = reqString(args, 'image');
    final confirmedPath = _consumeConfirmedPath(args, name);
    if (confirmedPath != null && confirmedPath != imagePath) {
      return AiToolResult.fail('Chemin modifié après confirmation.');
    }
    if (!await LibraryPathGuard.permits(
      imagePath, (await librarySongs(ctx.ref)).map((song) => song.filePath),
    )) {
      return AiToolResult.fail(
        'Image hors des dossiers de la bibliothèque ou chemin non sûr.',
      );
    }
    Uint8List bytes;
    try {
      final imageFile = File(imagePath);
      // Plafond : une pochette de 20 Mo et plus n'a rien à faire en tag —
      // et lire un fichier arbitraire d'un coup en mémoire, sans limite,
      // ouvrait la porte à une vidéo renommée en .jpg.
      if (await imageFile.length() > 20 * 1024 * 1024) {
        return AiToolResult.fail('Image trop volumineuse (limite 20 Mo).');
      }
      bytes = await imageFile.readAsBytes();
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
    if (!await LibraryPathGuard.permits(
      folder, (await librarySongs(ctx.ref)).map((song) => song.filePath),
    )) {
      throw const AiToolArgError(
        'Destination hors des dossiers de la bibliothèque ou chemin non sûr.',
      );
    }
    // Fige la liste confirmée : execute ne relira pas la bibliothèque ni le
    // morceau en cours.
    _freezeTargets(args, name, [
      for (final song in songs) (song: song, guess: null),
    ]);
    _freezeConfirmedPath(args, name, folder);
    if (songs.length == 1) {
      return 'Déplacer ${_forPreview(songLabel(songs.first))} vers :\n${_forPreview(folder)}';
    }
    return 'Déplacer ${songs.length} morceaux vers :\n${_forPreview(folder)}';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final folder = reqString(args, 'folder');
    // Liste confirmée par describeAction ; sans elle (appel direct),
    // résolution comme avant — AVANT de créer le dossier : un dossier
    // (potentiellement toute une arborescence) ne doit pas apparaître quand
    // aucun morceau n'est visé ou que la requête est ambiguë.
    final confirmed = _confirmedTargets(args, name);
    final songs = confirmed == null
        ? await _targets(ctx, args)
        : [for (final target in confirmed) target.song];
    if (songs.isEmpty) {
      return AiToolResult.fail('Aucun morceau visé.');
    }
    final confirmedPath = _consumeConfirmedPath(args, name);
    if (confirmedPath != null && confirmedPath != folder) {
      return AiToolResult.fail('Destination modifiée après confirmation.');
    }
    if (!await LibraryPathGuard.permits(
      folder, (await librarySongs(ctx.ref)).map((song) => song.filePath),
    )) {
      return AiToolResult.fail(
        'Destination hors des dossiers de la bibliothèque ou chemin non sûr.',
      );
    }
    final dir = Directory(folder);
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (e) {
      DebugLog.instance.warning(
        'OutilsFichiers',
        'Dossier inaccessible : $folder',
        error: e,
      );
      return AiToolResult.fail('Dossier inaccessible : $folder');
    }
    var moved = 0;
    var skipped = 0;
    for (final song in songs) {
      final target = p.join(dir.path, p.basename(song.filePath));
      if (await FileSystemEntity.type(song.filePath, followLinks: false) ==
          FileSystemEntityType.link) {
        skipped++;
        continue;
      }
      if (target == song.filePath) {
        skipped++;
        continue;
      }
      try {
        // Fenêtre TOCTOU résiduelle : voir BatchRenameFilesTool — même
        // limite Dart (pas de rename-if-absent), même couverture réaliste.
        if (await File(target).exists()) {
          skipped++;
          continue;
        }
        if (await _moveFile(File(song.filePath), target)) {
          // Chemin mis à jour avant le rescan : même si celui-ci lève, le
          // lecteur ne pointe plus vers l'ancien chemin.
          ctx.ref
              .read(audioPlayerServiceProvider)
              .updateSongPath(song.filePath, target);
          await MediaStore.rescan(target);
          moved++;
        } else {
          skipped++;
        }
      } catch (e) {
        DebugLog.instance.warning(
          'OutilsFichiers',
          'Déplacement impossible pour ${song.filePath}',
          error: e,
        );
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
