/// Outils de paroles : récupération, préparation pour le calage, décalage
/// d'affichage, récupération en lot.
///
/// L'assistant ne cale jamais lui-même : caler, c'est écouter l'audio, et un
/// modèle de langage n'entend rien. Il récupère et prépare ; l'utilisateur
/// cale au tap dans l'éditeur de synchro existant.
library;

import 'package:musync/core/router/app_router.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/data/playback_settings.dart';
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
  Map<String, Object?> get parametersSchema => {'type': 'object'};

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
    final best = results.first;
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
  Map<String, Object?> get parametersSchema => {'type': 'object'};

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
