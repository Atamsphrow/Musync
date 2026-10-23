/// Outils de paroles : récupération, préparation pour le calage, décalage
/// d'affichage, récupération en lot.
///
/// L'assistant ne cale jamais lui-même : caler, c'est écouter l'audio, et un
/// modèle de langage n'entend rien. Il récupère et prépare ; l'utilisateur
/// cale au tap dans l'éditeur de synchro existant.
library;

import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/router/app_router.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/providers/tag_change_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/data/playback_settings.dart';
import 'package:musync/features/settings/providers/backup_provider.dart';
import 'package:musync/features/settings/providers/playback_settings_provider.dart';

/// Cherche les paroles du morceau en cours et intègre le meilleur résultat.
class FetchLyricsTool extends AiTool {
  const FetchLyricsTool();

  @override
  String get name => 'fetch_lyrics';

  @override
  String get description =>
      'Récupère les paroles du morceau en cours depuis les sources '
      'configurées et les intègre au fichier (meilleur résultat).';

  @override
  Map<String, Object?> get parametersSchema =>
      {'type': 'object', 'properties': const {}};

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Récupérer les paroles du morceau en cours.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final song = ctx.ref.read(audioPlayerServiceProvider).currentSong;
    if (song == null) {
      return AiToolResult.fail('Aucun morceau en cours.');
    }
    final repository = ctx.ref.read(lyricsRepositoryProvider);
    final List<LyricsSearchResult> results;
    try {
      results = await repository.searchAll(
        title: song.title,
        artist: song.artist,
        album: song.album,
        durationMs: song.durationValue.inMilliseconds,
      );
    } catch (e) {
      return AiToolResult.fail('Recherche impossible : $e');
    }
    if (results.isEmpty) {
      return AiToolResult.fail(
        'Aucune parole trouvée pour ${songLabel(song)}.',
      );
    }
    // The shared pick: synced first, plain when no synced hit exists
    // (see bestLyricsMatch).
    final best = bestLyricsMatch(results) ?? results.first;
    try {
      await repository.embedLyrics(
        song.filePath,
        synced: best.syncedLyrics,
        unsynced: best.unsyncedLyrics,
      );
    } catch (e) {
      return AiToolResult.fail('Écriture impossible : $e');
    }
    ctx.ref.invalidate(currentLyricsProvider);
    final kind = best.hasSyncedLyrics ? 'synchronisées' : 'simples';
    return AiToolResult.ok(
      'Paroles $kind récupérées pour ${songLabel(song)} '
      '(source : ${best.source}).',
    );
  }
}

/// Récupère des paroles simples si besoin, puis ouvre l'éditeur de synchro.
///
/// C'est le seul « calage » que l'assistant fait : préparer le texte pour que
/// l'utilisateur le cale au tap. L'IA ne produit jamais de timestamps.
class PrepareLyricsForSyncTool extends AiTool {
  const PrepareLyricsForSyncTool();

  @override
  String get name => 'prepare_lyrics_for_sync';

  @override
  String get description =>
      'Prépare le calage des paroles du morceau en cours : récupère des '
      'paroles simples si le morceau n’en a pas, puis ouvre l’éditeur '
      'de synchronisation. L’IA ne cale pas elle-même.';

  @override
  Map<String, Object?> get parametersSchema =>
      {'type': 'object', 'properties': const {}};

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Préparer les paroles pour le calage (ouvre l’éditeur).';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final song = ctx.ref.read(audioPlayerServiceProvider).currentSong;
    if (song == null) {
      return AiToolResult.fail('Aucun morceau en cours.');
    }
    final repository = ctx.ref.read(lyricsRepositoryProvider);
    final pair = await repository.readLyrics(song.filePath);
    final syncedOk = pair.synced != null && pair.synced!.isNotEmpty;
    final plainOk = pair.unsynced != null && pair.unsynced!.text.trim().isNotEmpty;
    if (syncedOk) {
      return AiToolResult.ok(
        '${songLabel(song)} a déjà des paroles synchronisées.',
        navigateTo: AppRoutes.syncEditor,
        navigateArgs: SongRouteArgs(song: song),
      );
    }
    if (!plainOk) {
      final List<LyricsSearchResult> results;
      try {
        results = await repository.searchAll(
          title: song.title,
          artist: song.artist,
          album: song.album,
          durationMs: song.durationValue.inMilliseconds,
        );
      } catch (e) {
        return AiToolResult.fail('Recherche impossible : $e');
      }
      final plain = results.where((r) => r.hasUnsyncedLyrics).firstOrNull ??
          (results.isNotEmpty ? results.first : null);
      if (plain == null) {
        return AiToolResult.fail(
          'Aucune parole trouvée pour ${songLabel(song)}.',
        );
      }
      try {
        await repository.embedLyrics(
          song.filePath,
          synced: plain.syncedLyrics,
          unsynced: plain.unsyncedLyrics,
        );
      } catch (e) {
        return AiToolResult.fail('Écriture impossible : $e');
      }
      ctx.ref.invalidate(currentLyricsProvider);
    }
    return AiToolResult.ok(
      'Paroles prêtes — à toi de les caler au tap dans l’éditeur.',
      navigateTo: AppRoutes.syncEditor,
      navigateArgs: SongRouteArgs(song: song),
    );
  }
}

/// Règle le décalage d'affichage des paroles (compensation, en ms).
class AdjustLyricsOffsetTool extends AiTool {
  const AdjustLyricsOffsetTool();

  @override
  String get name => 'adjust_lyrics_offset';

  @override
  String get description =>
      'Règle le décalage d’affichage des paroles en millisecondes '
      '(positif = les lignes s’allument plus tard). Borné à ±1000 ms. '
      'Affichage uniquement, n’écrit jamais dans le fichier.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'milliseconds':
              'integer, requis — décalage en ms, entre -1000 et 1000',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final ms = optInt(args, 'milliseconds');
    return ms == null
        ? 'Régler le décalage des paroles.'
        : 'Régler le décalage des paroles à ${ms >= 0 ? '+' : ''}$ms ms.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final ms = reqInt(args, 'milliseconds')
        .clamp(-PlaybackSettings.maxOffsetMs, PlaybackSettings.maxOffsetMs);
    await ctx.ref
        .read(playbackSettingsProvider.notifier)
        .setOffset(Duration(milliseconds: ms));
    return AiToolResult.ok(
      'Décalage des paroles réglé à ${ms >= 0 ? '+' : ''}$ms ms.',
    );
  }
}

/// Récupère les paroles pour les morceaux qui n'en ont pas, en lot borné.
///
/// Écrit dans les fichiers : confirmation exigée, comme toute écriture.
class BatchFetchLyricsTool extends AiTool {
  const BatchFetchLyricsTool();

  @override
  String get name => 'batch_fetch_lyrics';

  @override
  String get description =>
      'Cherche et intègre les paroles pour les morceaux sans paroles, en '
      'lot. Borné (10 par défaut) : une bibliothèque entière prendrait trop '
      'de temps et d’appels.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'max':
              'integer, optionnel — nombre max de morceaux (défaut 10, max 50)',
        },
      };

  @override
  bool get requiresConfirmation => true;

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final max = (optInt(args, 'max') ?? 10).clamp(1, 50);
    return 'Chercher et intégrer les paroles pour jusqu’à $max morceaux '
        'sans paroles.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final max = (optInt(args, 'max') ?? 10).clamp(1, 50);
    final byStatus =
        ctx.ref.read(songsByStatusProvider).valueOrNull;
    final candidates = byStatus?[LyricsStatus.none] ?? const [];
    if (candidates.isEmpty) {
      return AiToolResult.ok('Aucun morceau sans paroles.');
    }
    final repository = ctx.ref.read(lyricsRepositoryProvider);
    var done = 0;
    var tried = 0;
    for (final song in candidates.take(max)) {
      tried++;
      try {
        final results = await repository.searchAll(
          title: song.title,
          artist: song.artist,
          album: song.album,
          durationMs: song.durationValue.inMilliseconds,
        );
        if (results.isEmpty) continue;
        final best = results.first;
        await repository.embedLyrics(
          song.filePath,
          synced: best.syncedLyrics,
          unsynced: best.unsyncedLyrics,
        );
        done++;
      } catch (_) {
        // Un morceau raté n'arrête pas le lot.
      }
    }
    ctx.ref.invalidate(currentLyricsProvider);
    return AiToolResult.ok(
      'Paroles intégrées pour $done morceau${done > 1 ? 'x' : ''} '
      '($tried essayé${tried > 1 ? 's' : ''}).',
    );
  }
}

// ---- écritures paroles avec sauvegarde ------------------------------------

/// Écrit des paroles avec le protocole backup + historique : chaque écriture
/// est annulable depuis Paramètres › Historique, comme les écritures auto.
///
/// Rend vrai quand l'écriture a eu lieu.
Future<bool> _writeLyricsUndoable(
  Ref ref,
  Song song, {
  SyncedLyrics? synced,
  UnsyncedLyrics? unsynced,
}) async {
  final backups = ref.read(tagBackupStoreProvider);
  final changes = ref.read(tagChangeProvider);
  final repository = ref.read(lyricsRepositoryProvider);
  final canUndo = await backups.capture(song.filePath);
  try {
    await repository.embedLyrics(
      song.filePath,
      synced: synced,
      unsynced: unsynced,
    );
  } catch (_) {
    if (canUndo) await backups.discardLatest(song.filePath);
    return false;
  }
  if (canUndo) await backups.markWritten(song.filePath);
  changes.fileChanged(song.filePath);
  return true;
}

/// Morceaux visés par les outils de paroles : le morceau en cours par défaut,
/// ou tous les morceaux synchronisés quand scope vaut 'all'.
Future<List<Song>> _lyricsScope(
  AiToolContext ctx,
  Map<String, Object?> args,
) async {
  if ((optString(args, 'scope') ?? 'current') == 'all') {
    final byStatus = ctx.ref.read(songsByStatusProvider).valueOrNull;
    return [...(byStatus?[LyricsStatus.synced] ?? const <Song>[])];
  }
  final song = ctx.ref.read(audioPlayerServiceProvider).currentSong;
  return song == null ? const [] : [song];
}

String _plural(int n, String one, String many) =>
    n > 1 ? '$n $many' : '$n $one';

/// Lit les paroles d'un morceau, ou null si illisibles.
Future<LyricsPair?> _readPair(AiToolContext ctx, Song song) async {
  try {
    return await ctx.ref.read(lyricsRepositoryProvider).readLyrics(
          song.filePath,
        );
  } catch (_) {
    return null;
  }
}

/// Nombre de lignes finales vides qu'on peut couper (0 = rien à faire).
int _trailingEmptyCount(SyncedLyrics? synced) {
  if (synced == null || synced.isEmpty) return 0;
  var end = synced.lines.length;
  while (end > 0 && synced.lines[end - 1].text.trim().isEmpty) {
    end--;
  }
  // Rien à couper, ou il ne resterait rien : on ne touche pas.
  if (end == synced.lines.length || end == 0) return 0;
  return synced.lines.length - end;
}

/// Nombre de lignes que le nettoyage retirerait (0 = déjà propre).
int _cleanableCount(SyncedLyrics? synced) {
  if (synced == null || synced.isEmpty) return 0;
  var removed = 0;
  var kept = 0;
  String? last;
  for (final line in synced.lines) {
    final text = line.text.trim();
    if (text.isEmpty) {
      removed++;
      continue;
    }
    if (last != null && last == text) {
      removed++;
      continue;
    }
    last = text;
    kept++;
  }
  // On ne vide jamais complètement des paroles existantes.
  if (kept == 0) return 0;
  return removed;
}

/// Vérifie le morceau en cours : identité, fichier, état des paroles.
///
/// Lecture seule : ne touche à rien.
class CheckCurrentSongTool extends AiTool {
  const CheckCurrentSongTool();

  @override
  String get name => 'check_current_song';

  @override
  String get description =>
      'Vérifie le morceau en cours : titre, artiste, album, durée, chemin du '
      'fichier et état de ses paroles (synchronisées avec le nombre de '
      'lignes, simples, ou absentes). Lecture seule.';

  @override
  Map<String, Object?> get parametersSchema =>
      {'type': 'object', 'properties': const {}};

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Vérifier le morceau en cours.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final song = ctx.ref.read(audioPlayerServiceProvider).currentSong;
    if (song == null) {
      return AiToolResult.fail('Aucun morceau en cours.');
    }
    final d = song.durationValue;
    final dur =
        '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    LyricsStatus? status;
    try {
      status = await ctx.ref
          .read(lyricsStatusScannerProvider)
          .statusOf(song.filePath);
    } catch (_) {
      // Le statut reste inconnu : on le dit, on ne l'invente pas.
    }
    final lyrics = ctx.ref.read(currentLyricsProvider).valueOrNull;
    final syncedLines = lyrics?.synced?.lines.length;
    final plainChars = lyrics?.unsynced?.text.trim().length;
    final lyricsState = switch (status) {
      LyricsStatus.synced => 'synchronisées (${syncedLines ?? '?'} lignes)',
      LyricsStatus.plain => 'simples (${plainChars ?? '?'} caractères)',
      LyricsStatus.none => 'absentes',
      null => 'état inconnu',
    };
    return AiToolResult.ok(
      '${songLabel(song)} — album « ${song.album} », $dur\n'
      'Fichier : ${song.filePath}\n'
      'Paroles : $lyricsState.',
    );
  }
}

/// Supprime la ou les dernières lignes vides des paroles synchronisées.
///
/// Ce sont ces timestamps sans texte en fin de morceau que l'utilisateur
/// n'aime pas voir. Morceau en cours par défaut, toute la bibliothèque
/// avec scope='all'. Écriture avec sauvegarde : annulable dans
/// Paramètres › Historique.
class TrimEmptyLastLyricLineTool extends AiTool {
  const TrimEmptyLastLyricLineTool();

  @override
  String get name => 'trim_empty_last_lyric_line';

  @override
  String get description =>
      'Supprime la ou les dernières lignes vides des paroles synchronisées '
      '(un timestamp sans texte en fin de morceau). Cible : le morceau en '
      'cours par défaut, ou toute la bibliothèque avec scope="all". '
      'Écriture avec sauvegarde, annulable dans Paramètres › Historique.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'scope':
              'string, optionnel — "current" (défaut) ou "all" pour toute la bibliothèque',
        },
      };

  @override
  bool get requiresConfirmation => true;

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final songs = await _lyricsScope(ctx, args);
    if (songs.isEmpty) {
      throw const AiToolArgError('Aucun morceau en cours.');
    }
    if (songs.length == 1) {
      final song = songs.first;
      // Pas de dialogue quand il n'y a rien à couper : on le dit, on ne
      // fait pas confirmer du vide.
      final pair = await _readPair(ctx, song);
      if (_trailingEmptyCount(pair?.synced) == 0) {
        throw AiToolArgError(
          '${songLabel(song)} n’a pas de ligne vide à la fin de ses paroles '
          'synchronisées — rien à faire.',
        );
      }
      return 'Supprimer la dernière ligne vide des paroles synchronisées '
          'de ${songLabel(song)}.';
    }
    return 'Supprimer la dernière ligne vide des paroles synchronisées de '
        '${songs.length} morceaux.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final songs = await _lyricsScope(ctx, args);
    if (songs.isEmpty) {
      return AiToolResult.fail('Aucun morceau en cours.');
    }
    final repository = ctx.ref.read(lyricsRepositoryProvider);
    var trimmed = 0;
    var clean = 0;
    var failed = 0;
    for (final song in songs) {
      LyricsPair pair;
      try {
        pair = await repository.readLyrics(song.filePath);
      } catch (_) {
        failed++;
        continue;
      }
      final synced = pair.synced;
      final cuttable = _trailingEmptyCount(synced);
      if (cuttable == 0) {
        // Rien à couper, ou il ne resterait rien : on ne touche pas.
        clean++;
        continue;
      }
      final kept = SyncedLyrics(
        synced!.lines.sublist(0, synced.lines.length - cuttable),
      );
      final ok = await _writeLyricsUndoable(
        ctx.ref,
        song,
        synced: kept,
        unsynced: pair.unsynced,
      );
      if (ok) {
        trimmed++;
      } else {
        failed++;
      }
    }
    ctx.ref.invalidate(currentLyricsProvider);
    final parts = <String>[
      _plural(trimmed, 'morceau nettoyé', 'morceaux nettoyés'),
    ];
    if (clean > 0) parts.add('$clean sans ligne vide finale');
    if (failed > 0) parts.add('$failed échec(s)');
    return AiToolResult.ok('Dernière ligne vide supprimée : ${parts.join(', ')}.');
  }
}

/// Nettoie les paroles synchronisées : lignes vides au milieu et lignes
/// en double consécutives.
///
/// Morceau en cours par défaut, toute la bibliothèque avec scope='all'.
/// Écriture avec sauvegarde : annulable dans Paramètres › Historique.
class CleanLyricsTool extends AiTool {
  const CleanLyricsTool();

  @override
  String get name => 'clean_lyrics';

  @override
  String get description =>
      'Nettoie les paroles synchronisées : supprime les lignes vides et les '
      'lignes en double qui se suivent. Cible : le morceau en cours par '
      'défaut, ou toute la bibliothèque avec scope="all". Écriture avec '
      'sauvegarde, annulable dans Paramètres › Historique.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'scope':
              'string, optionnel — "current" (défaut) ou "all" pour toute la bibliothèque',
        },
      };

  @override
  bool get requiresConfirmation => true;

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final songs = await _lyricsScope(ctx, args);
    if (songs.isEmpty) {
      throw const AiToolArgError('Aucun morceau en cours.');
    }
    if (songs.length == 1) {
      final song = songs.first;
      final pair = await _readPair(ctx, song);
      if (_cleanableCount(pair?.synced) == 0) {
        throw AiToolArgError(
          '${songLabel(song)} : paroles déjà propres — rien à faire.',
        );
      }
      return 'Nettoyer les paroles synchronisées de '
          '${songLabel(song)} (lignes vides, doublons).';
    }
    return 'Nettoyer les paroles synchronisées de ${songs.length} morceaux '
        '(lignes vides, doublons).';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final songs = await _lyricsScope(ctx, args);
    if (songs.isEmpty) {
      return AiToolResult.fail('Aucun morceau en cours.');
    }
    final repository = ctx.ref.read(lyricsRepositoryProvider);
    var cleaned = 0;
    var clean = 0;
    var failed = 0;
    for (final song in songs) {
      LyricsPair pair;
      try {
        pair = await repository.readLyrics(song.filePath);
      } catch (_) {
        failed++;
        continue;
      }
      final synced = pair.synced;
      if (synced == null || synced.isEmpty) {
        clean++;
        continue;
      }
      final kept = <LyricLine>[];
      var removed = 0;
      for (final line in synced.lines) {
        if (line.text.trim().isEmpty) {
          removed++;
          continue;
        }
        if (kept.isNotEmpty &&
            kept.last.text.trim() == line.text.trim()) {
          removed++;
          continue;
        }
        kept.add(line);
      }
      if (removed == 0 || kept.isEmpty) {
        clean++;
        continue;
      }
      final ok = await _writeLyricsUndoable(
        ctx.ref,
        song,
        synced: SyncedLyrics(kept),
        unsynced: pair.unsynced,
      );
      if (ok) {
        cleaned++;
      } else {
        failed++;
      }
    }
    ctx.ref.invalidate(currentLyricsProvider);
    final parts = <String>[
      _plural(cleaned, 'morceau nettoyé', 'morceaux nettoyés'),
    ];
    if (clean > 0) parts.add('$clean déjà propres');
    if (failed > 0) parts.add('$failed échec(s)');
    return AiToolResult.ok('Paroles nettoyées : ${parts.join(', ')}.');
  }
}

/// Décale les timestamps des paroles synchronisées DANS le fichier.
///
/// Contrairement au réglage d'affichage (±1000 ms, temporaire), ceci réécrit
/// réellement les temps. Borné à ±10000 ms. Morceau en cours par défaut,
/// toute la bibliothèque avec scope='all'. Écriture avec sauvegarde :
/// annulable dans Paramètres › Historique.
class ShiftLyricsTimestampsTool extends AiTool {
  const ShiftLyricsTimestampsTool();

  static const int maxShiftMs = 10000;

  @override
  String get name => 'shift_lyrics_timestamps';

  @override
  String get description =>
      'Décale les timestamps des paroles synchronisées dans le fichier '
      '(positif = les lignes s’allument plus tard). Écriture réelle, '
      'bornée à ±10000 ms. Cible : le morceau en cours par défaut, ou toute '
      'la bibliothèque avec scope="all". Annulable dans '
      'Paramètres › Historique.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'milliseconds':
              'integer, requis — décalage en ms, entre -10000 et 10000',
          'scope':
              'string, optionnel — "current" (défaut) ou "all" pour toute la bibliothèque',
        },
      };

  @override
  bool get requiresConfirmation => true;

  int _shift(Map<String, Object?> args) =>
      reqInt(args, 'milliseconds').clamp(-maxShiftMs, maxShiftMs);

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final ms = _shift(args);
    final songs = await _lyricsScope(ctx, args);
    if (songs.isEmpty) {
      throw const AiToolArgError('Aucun morceau en cours.');
    }
    final dir = ms >= 0 ? '+' : '−';
    if (songs.length == 1) {
      final song = songs.first;
      final pair = await _readPair(ctx, song);
      if (pair?.synced == null || pair!.synced!.isEmpty) {
        throw AiToolArgError(
          '${songLabel(song)} n’a pas de paroles synchronisées — rien à décaler.',
        );
      }
      return 'Décaler les paroles synchronisées de '
          '${songLabel(song)} de $dir${ms.abs()} ms dans le fichier.';
    }
    return 'Décaler les paroles synchronisées de ${songs.length} morceaux '
        'de $dir${ms.abs()} ms dans le fichier.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final ms = _shift(args);
    if (ms == 0) {
      return AiToolResult.fail('Décalage nul : rien à faire.');
    }
    final songs = await _lyricsScope(ctx, args);
    if (songs.isEmpty) {
      return AiToolResult.fail('Aucun morceau en cours.');
    }
    final repository = ctx.ref.read(lyricsRepositoryProvider);
    final delta = Duration(milliseconds: ms);
    var shifted = 0;
    var clean = 0;
    var failed = 0;
    for (final song in songs) {
      LyricsPair pair;
      try {
        pair = await repository.readLyrics(song.filePath);
      } catch (_) {
        failed++;
        continue;
      }
      final synced = pair.synced;
      if (synced == null || synced.isEmpty) {
        clean++;
        continue;
      }
      final moved = SyncedLyrics([
        for (final line in synced.lines)
          if (line.timestamp == null)
            line
          else
            line.copyWith(
              timestamp: (line.timestamp! + delta).isNegative
                  ? Duration.zero
                  : line.timestamp! + delta,
            ),
      ]);
      final ok = await _writeLyricsUndoable(
        ctx.ref,
        song,
        synced: moved,
        unsynced: pair.unsynced,
      );
      if (ok) {
        shifted++;
      } else {
        failed++;
      }
    }
    ctx.ref.invalidate(currentLyricsProvider);
    final dir = ms >= 0 ? '+' : '−';
    final parts = <String>[
      _plural(shifted, 'morceau décalé', 'morceaux décalés'),
    ];
    if (clean > 0) parts.add('$clean sans paroles synchronisées');
    if (failed > 0) parts.add('$failed échec(s)');
    return AiToolResult.ok(
        'Timestamps décalés de $dir${ms.abs()} ms : ${parts.join(', ')}.');
  }
}

/// Corrige le texte d'une ligne précise des paroles synchronisées.
///
/// La ligne est désignée par son numéro (1 = première ligne). Écriture avec
/// sauvegarde : annulable dans Paramètres › Historique.
class FixLyricLineTool extends AiTool {
  const FixLyricLineTool();

  @override
  String get name => 'fix_lyric_line';

  @override
  String get description =>
      'Corrige le texte d’une ligne précise des paroles synchronisées du '
      'morceau en cours (line : numéro de ligne, 1 = première). Le timestamp '
      'est conservé. Écriture avec sauvegarde, annulable dans '
      'Paramètres › Historique.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'line': 'integer, requis — numéro de ligne (1 = première)',
          'text': 'string, requis — nouveau texte de la ligne',
        },
      };

  @override
  bool get requiresConfirmation => true;

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final song = ctx.ref.read(audioPlayerServiceProvider).currentSong;
    if (song == null) {
      throw const AiToolArgError('Aucun morceau en cours.');
    }
    final index = reqInt(args, 'line') - 1;
    final text = reqString(args, 'text');
    final pair =
        await ctx.ref.read(lyricsRepositoryProvider).readLyrics(song.filePath);
    final synced = pair.synced;
    if (synced == null || index < 0 || index >= synced.lines.length) {
      throw AiToolArgError(
        'Ligne ${index + 1} inexistante '
        '(${synced?.lines.length ?? 0} lignes synchronisées).',
      );
    }
    return 'Corriger la ligne ${index + 1} de ${songLabel(song)} :\n'
        '« ${synced.lines[index].text} » → « $text »';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final song = ctx.ref.read(audioPlayerServiceProvider).currentSong;
    if (song == null) {
      return AiToolResult.fail('Aucun morceau en cours.');
    }
    final index = reqInt(args, 'line') - 1;
    final text = reqString(args, 'text');
    final repository = ctx.ref.read(lyricsRepositoryProvider);
    LyricsPair pair;
    try {
      pair = await repository.readLyrics(song.filePath);
    } catch (_) {
      return AiToolResult.fail(
          'Lecture impossible pour ${songLabel(song)}.');
    }
    final synced = pair.synced;
    if (synced == null || index < 0 || index >= synced.lines.length) {
      return AiToolResult.fail(
        'Ligne ${index + 1} inexistante '
        '(${synced?.lines.length ?? 0} lignes synchronisées).',
      );
    }
    final lines = [...synced.lines];
    lines[index] = lines[index].copyWith(text: text);
    final ok = await _writeLyricsUndoable(
      ctx.ref,
      song,
      synced: SyncedLyrics(lines),
      unsynced: pair.unsynced,
    );
    ctx.ref.invalidate(currentLyricsProvider);
    return ok
        ? AiToolResult.ok('Ligne ${index + 1} corrigée pour ${songLabel(song)}.')
        : AiToolResult.fail('Écriture impossible pour ${songLabel(song)}.');
  }
}

/// Supprime les paroles d'un morceau ou de tout un lot.
///
/// Morceau en cours par défaut ; scope='all' pour tous les morceaux qui ont
/// des paroles. Écriture avec sauvegarde : annulable dans
/// Paramètres › Historique.
class RemoveLyricsTool extends AiTool {
  const RemoveLyricsTool();

  @override
  String get name => 'remove_lyrics';

  @override
  String get description =>
      'Supprime les paroles (synchronisées et simples) du morceau en cours, '
      'ou de tous les morceaux qui en ont avec scope="all". Écriture avec '
      'sauvegarde, annulable dans Paramètres › Historique.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'scope':
              'string, optionnel — "current" (défaut) ou "all" pour tous les morceaux avec paroles',
        },
      };

  @override
  bool get requiresConfirmation => true;

  Future<List<Song>> _targets(AiToolContext ctx, Map<String, Object?> args) async {
    if ((optString(args, 'scope') ?? 'current') == 'all') {
      final byStatus = ctx.ref.read(songsByStatusProvider).valueOrNull;
      return [
        ...(byStatus?[LyricsStatus.synced] ?? const <Song>[]),
        ...(byStatus?[LyricsStatus.plain] ?? const <Song>[]),
      ];
    }
    final song = ctx.ref.read(audioPlayerServiceProvider).currentSong;
    return song == null ? const [] : [song];
  }

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final songs = await _targets(ctx, args);
    if (songs.isEmpty) {
      throw const AiToolArgError('Aucun morceau en cours.');
    }
    if (songs.length == 1) {
      final song = songs.first;
      final pair = await _readPair(ctx, song);
      final hasAny = (pair?.synced?.isNotEmpty ?? false) ||
          (pair?.unsynced?.isNotEmpty ?? false);
      if (!hasAny) {
        throw AiToolArgError(
          '${songLabel(song)} n’a déjà pas de paroles — rien à faire.',
        );
      }
      return 'Supprimer les paroles de ${songLabel(song)}.';
    }
    return 'Supprimer les paroles de ${songs.length} morceaux.';
  }

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final songs = await _targets(ctx, args);
    if (songs.isEmpty) {
      return AiToolResult.fail('Aucun morceau en cours.');
    }
    final repository = ctx.ref.read(lyricsRepositoryProvider);
    var removed = 0;
    var clean = 0;
    var failed = 0;
    for (final song in songs) {
      LyricsPair pair;
      try {
        pair = await repository.readLyrics(song.filePath);
      } catch (_) {
        failed++;
        continue;
      }
      final hasAny = (pair.synced?.isNotEmpty ?? false) ||
          (pair.unsynced?.isNotEmpty ?? false);
      if (!hasAny) {
        clean++;
        continue;
      }
      final ok = await _writeLyricsUndoable(ctx.ref, song);
      if (ok) {
        removed++;
      } else {
        failed++;
      }
    }
    ctx.ref.invalidate(currentLyricsProvider);
    final parts = <String>[
      _plural(removed, 'paroles supprimées', 'paroles supprimées'),
    ];
    if (clean > 0) parts.add('$clean déjà sans paroles');
    if (failed > 0) parts.add('$failed échec(s)');
    return AiToolResult.ok('Paroles supprimées : ${parts.join(', ')}.');
  }
}
