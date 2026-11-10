/// Le service unique « trouver des paroles » (DESIGN.md §5).
///
/// Un seul chemin pour l'IA, le fond et le lot : résoudre l'identité,
/// chercher sur les sources configurées, scorer, intégrer quand c'est
/// sûr. Orchestration sans UI, réutilisable par l'outil IA, l'écran
/// lecteur et le fond.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/tag_backup.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/data/lyrics_confidence.dart';
import 'package:musync/features/lyrics/data/lyrics_mismatch_store.dart';
import 'package:musync/features/lyrics/data/lyrics_provenance.dart';
import 'package:musync/features/lyrics/data/lyrics_query_resolver.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/lyrics/providers/tag_change_provider.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';
import 'package:musync/features/settings/providers/backup_provider.dart';

enum LyricsFindVerdict { integrated, needsChoice, notFound, keptExisting }

/// Le résultat d'une recherche + tentative d'intégration.
class LyricsFindResult {
  final LyricsFindVerdict verdict;

  /// Meilleur candidat, quel que soit le seuil (null si rien trouvé).
  final LyricsSearchResult? best;

  /// Top 3 rescorés, pour l'affichage.
  final List<LyricsSearchResult> top;

  final double bestConfidence;

  /// La requête qui a produit le meilleur candidat.
  final String queriedTitle;
  final String queriedArtist;

  /// Vrai quand le meilleur venait de la devinette nom de fichier.
  final bool viaFilename;

  /// Vrai si des paroles existantes ont été remplacées.
  final bool replacedPrevious;

  /// Message en français, prêt à afficher.
  final String? note;

  /// Vrai quand la requête était de bonne qualité (pour SweepMemory :
  /// seul un « rien trouvé » sur une bonne requête mérite d'être cru).
  final bool queryGoodQuality;

  /// Vrai quand aucune recherche n'a abouti (sources injoignables) :
  /// un « rien trouvé » dans ce cas ne prouve rien et ne doit pas être
  /// mémorisé comme une absence confirmée.
  final bool searchesFailed;

  const LyricsFindResult({
    required this.verdict,
    this.best,
    this.top = const [],
    this.bestConfidence = 0.0,
    this.queriedTitle = '',
    this.queriedArtist = '',
    this.viaFilename = false,
    this.replacedPrevious = false,
    this.note,
    this.queryGoodQuality = false,
    this.searchesFailed = false,
  });
}

enum LyricsVerifyVerdict { plausible, suspicious, protected, unknown }

/// Le diagnostic de `verifyFor` : lecture seule, sans écriture.
class LyricsVerifyResult {
  final LyricsVerifyVerdict verdict;

  /// Le message en français, prêt à afficher.
  final String message;

  /// La recherche à sec qui fonde le diagnostic.
  final LyricsFindResult find;

  const LyricsVerifyResult({
    required this.verdict,
    required this.message,
    required this.find,
  });
}

class AiLyricsFinder {
  final LyricsRepository repository;
  final LyricsQueryResolver resolver;
  final LyricsProvenanceStore provenance;
  final TagBackupStore backups;

  /// Morceaux marqués « non correspondant » : jamais de recherche ni
  /// d'écriture automatique pour eux.
  final LyricsMismatchStore mismatchStore;

  /// Appelé après une écriture (invalidation des caches). En production :
  /// `TagChangeService.fileChanged`.
  final void Function(String filePath) fileChanged;

  /// Accès écriture (pas de prompt depuis un chemin automatique).
  final Future<bool> Function() hasWriteAccess;

  AiLyricsFinder({
    required this.repository,
    required this.resolver,
    required this.provenance,
    required this.backups,
    required this.mismatchStore,
    required this.fileChanged,
    Future<bool> Function()? hasWriteAccess,
  }) : hasWriteAccess =
           hasWriteAccess ?? PermissionService.hasWriteAccess;

  /// Trouver et intégrer si sûr.
  ///
  /// [origin] est la provenance enregistrée en cas d'écriture.
  /// [dryRun] ne fait que décider : rien n'est écrit, le verdict
  /// `integrated` signifie alors « intégrerait ».
  Future<LyricsFindResult> findFor(
    Song song, {
    bool aiFallback = true,
    bool dryRun = false,
    LyricsProvenanceOrigin origin = LyricsProvenanceOrigin.autoAi,
  }) async {
    // Marqué « non correspondant » : plus aucun téléchargement
    // automatique pour ce morceau — ni recherche (même pas la
    // résolution d'identité, qui peut appeler l'IA), ni écriture.
    if (await mismatchStore.isMismatched(
      song.filePath,
      title: song.title,
      artist: song.artist,
    )) {
      _log('marqué non correspondant', song, 0, '');
      return const LyricsFindResult(
        verdict: LyricsFindVerdict.keptExisting,
        note:
            'Morceau marqué non correspondant : aucune recherche automatique.',
      );
    }

    final resolved = await resolver.resolve(song, aiFallback: aiFallback);
    if (resolved.queries.isEmpty) {
      _log('rien trouvé', song, 0, '');
      return const LyricsFindResult(
        verdict: LyricsFindVerdict.notFound,
        note: 'Impossible de deviner le titre et l\'artiste de ce morceau.',
      );
    }

    final scored = <LyricsSearchResult>[];
    final seen = <String>{};
    var anySearchRan = false;
    for (final query in resolved.queries) {
      List<LyricsSearchResult> results;
      try {
        results = await repository.searchAll(
          title: query.title,
          artist: query.artist,
          album: query.album,
          durationMs: song.duration,
          filenameGuess: resolved.filenameGuess,
        );
        anySearchRan = true;
      } catch (_) {
        // Une requête ratée (source injoignable) ne condamne pas l'autre.
        continue;
      }
      // Un `/get` à 1,0 sur des tags contredits par le nom de fichier ne
      // doit plus être une certitude : plafonné à 0,80 (DESIGN.md §3).
      final contradicted =
          query.origin == LyricsQueryOrigin.tags &&
          filenameGuessContradictsQuery(
            resolved.filenameGuess,
            queryTitle: query.title,
            queryArtist: query.artist,
          );
      for (final result in results) {
        final score = scoreLyricsCandidate(
          candidateTitle: result.title,
          candidateArtist: result.artist,
          candidateAlbum: result.album,
          candidateDurationMs: result.durationMs,
          candidateHasSynced: result.hasSyncedLyrics,
          queryTitle: query.title,
          queryArtist: query.artist,
          queryAlbum: query.album,
          queryDurationMs: song.duration,
          filenameGuess: resolved.filenameGuess,
        );
        var confidence = score.total;
        if (contradicted) confidence = confidence.clamp(0.0, 0.80);
        // Dédoublonnage entre les deux requêtes : même enregistrement
        // trouvé deux fois, on garde le meilleur score.
        final key = result.trackId != null
            ? 'id:${result.trackId}'
            : 'n:${result.source}|'
                  '${normalizeForConfidence(result.title)}|'
                  '${normalizeForConfidence(result.artist)}';
        final rescored = LyricsSearchResult(
          source: result.source,
          title: result.title,
          artist: result.artist,
          album: result.album,
          syncedLyrics: result.syncedLyrics,
          unsyncedLyrics: result.unsyncedLyrics,
          confidence: confidence,
          trackId: result.trackId,
          durationMs: result.durationMs,
        );
        if (seen.add(key)) {
          scored.add(rescored);
        } else {
          final at = scored.indexWhere(
            (r) =>
                (r.trackId != null
                    ? 'id:${r.trackId}'
                    : 'n:${r.source}|'
                          '${normalizeForConfidence(r.title)}|'
                          '${normalizeForConfidence(r.artist)}') ==
                key,
          );
          if (at >= 0 && confidence > scored[at].confidence) {
            scored[at] = rescored;
          }
        }
      }
    }

    // Stable : `sort` ne l'est pas, et deux candidats à égalité ne
    // doivent pas permuter entre deux recherches.
    final ranked = List<({int index, LyricsSearchResult result})>.generate(
      scored.length,
      (i) => (index: i, result: scored[i]),
      growable: false,
    )..sort((a, b) {
      final byConfidence = b.result.confidence.compareTo(a.result.confidence);
      return byConfidence != 0 ? byConfidence : a.index.compareTo(b.index);
    });
    final sorted = [for (final e in ranked) e.result];
    final top = sorted.take(3).toList();
    final bestConfidence = top.isEmpty ? 0.0 : top.first.confidence;

    // La requête qui a produit le meilleur candidat : celle dont le
    // titre/artiste rescorent le plus haut — en pratique on la retrouve
    // en rescorant le meilleur contre chaque requête.
    var queriedTitle = resolved.primary.title;
    var queriedArtist = resolved.primary.artist;
    var viaFilename = resolved.primary.origin != LyricsQueryOrigin.tags;
    if (top.isNotEmpty) {
      var bestScore = -1.0;
      for (final query in resolved.queries) {
        final score = scoreLyricsCandidate(
          candidateTitle: top.first.title,
          candidateArtist: top.first.artist,
          candidateAlbum: top.first.album,
          candidateDurationMs: top.first.durationMs,
          candidateHasSynced: top.first.hasSyncedLyrics,
          queryTitle: query.title,
          queryArtist: query.artist,
          queryAlbum: query.album,
          queryDurationMs: song.duration,
          filenameGuess: resolved.filenameGuess,
        ).total;
        if (score > bestScore) {
          bestScore = score;
          queriedTitle = query.title;
          queriedArtist = query.artist;
          viaFilename = query.origin != LyricsQueryOrigin.tags;
        }
      }
    }

    if (!anySearchRan) {
      // Aucune source n'a répondu : ce n'est pas une absence, c'est
      // une panne — rien ne doit être mémorisé comme « rien trouvé ».
      return LyricsFindResult(
        verdict: LyricsFindVerdict.notFound,
        note: 'Recherche impossible : aucune source de paroles ne répond.',
        queryGoodQuality: resolved.goodQuality,
        searchesFailed: true,
      );
    }

    final best = bestAutoMatch(
      sorted,
      minConfidence: LyricsConfidence.autoIntegrateConfidence,
    );
    if (best == null) {
      final verdict = bestConfidence >= LyricsConfidence.proposeConfidence
          ? LyricsFindVerdict.needsChoice
          : LyricsFindVerdict.notFound;
      final note = verdict == LyricsFindVerdict.needsChoice
          ? 'Paroles trouvées avec une confiance de '
                '${(bestConfidence * 100).round()} % — pas assez pour '
                'les intégrer seul.'
          : 'Aucune parole trouvée avec assez de certitude.';
      _log(
        verdict == LyricsFindVerdict.needsChoice ? 'proposé' : 'refusé',
        song,
        bestConfidence,
        '$queriedTitle — $queriedArtist',
      );
      return LyricsFindResult(
        verdict: verdict,
        best: top.isEmpty ? null : top.first,
        top: top,
        bestConfidence: bestConfidence,
        queriedTitle: queriedTitle,
        queriedArtist: queriedArtist,
        viaFilename: viaFilename,
        note: note,
        queryGoodQuality: resolved.goodQuality,
      );
    }

    final current = await _readCurrent(song.filePath);
    final currentProvenance = await provenance.forPath(song.filePath);
    final decision = _decideWrite(
      best: best,
      current: current,
      currentProvenance: currentProvenance,
    );
    if (decision != null) {
      // Refus de principe (protégé, calé gardé) : rien d'écrit, on
      // propose.
      _log('gardé', song, best.confidence, '$queriedTitle — $queriedArtist');
      return LyricsFindResult(
        verdict: decision,
        best: best,
        top: top,
        bestConfidence: best.confidence,
        queriedTitle: queriedTitle,
        queriedArtist: queriedArtist,
        viaFilename: viaFilename,
        note: _keptNote(best, current, currentProvenance),
        queryGoodQuality: resolved.goodQuality,
      );
    }

    if (dryRun) {
      return LyricsFindResult(
        verdict: LyricsFindVerdict.integrated,
        best: best,
        top: top,
        bestConfidence: best.confidence,
        queriedTitle: queriedTitle,
        queriedArtist: queriedArtist,
        viaFilename: viaFilename,
        replacedPrevious: _hasAnyLyrics(current),
        note: 'Intégrerait « ${best.title} » — ${best.artist} '
            '(confiance ${(best.confidence * 100).round()} %).',
        queryGoodQuality: resolved.goodQuality,
      );
    }

    final written = await _integrate(
      song: song,
      best: best,
      current: current,
      queriedTitle: queriedTitle,
      queriedArtist: queriedArtist,
      viaFilename: viaFilename,
      origin: origin,
    );
    if (written == null) {
      return LyricsFindResult(
        verdict: LyricsFindVerdict.keptExisting,
        best: best,
        top: top,
        bestConfidence: best.confidence,
        queriedTitle: queriedTitle,
        queriedArtist: queriedArtist,
        viaFilename: viaFilename,
        note: 'Écriture impossible : sauvegarde ou accès refusé, '
            'rien n\'a été modifié.',
        queryGoodQuality: resolved.goodQuality,
      );
    }
    _log('intégré', song, best.confidence, '$queriedTitle — $queriedArtist');
    final kind = best.hasSyncedLyrics ? 'synchronisées' : 'simples';
    return LyricsFindResult(
      verdict: LyricsFindVerdict.integrated,
      best: best,
      top: top,
      bestConfidence: best.confidence,
      queriedTitle: queriedTitle,
      queriedArtist: queriedArtist,
      viaFilename: viaFilename,
      replacedPrevious: _hasAnyLyrics(current),
      note: 'Paroles $kind intégrées pour « ${song.title} » — '
          '${song.artist} (source ${best.source}, '
          'confiance ${(best.confidence * 100).round()} %).',
      queryGoodQuality: resolved.goodQuality,
    );
  }

  /// Remplace les paroles du morceau en cours par [candidate], sur choix
  /// explicite de l'utilisateur (confirmation déjà obtenue par l'appelant).
  ///
  /// Même garde-fous d'écriture que `findFor` (backup strict, pas de
  /// texte seul sur du calé), sauf la protection des paroles utilisateur :
  /// l'utilisateur a choisi, il peut les remplacer.
  Future<LyricsFindResult> replaceWith(
    Song song,
    LyricsSearchResult candidate, {
    LyricsProvenanceOrigin origin = LyricsProvenanceOrigin.autoAi,
    String queriedTitle = '',
    String queriedArtist = '',
  }) async {
    final current = await _readCurrent(song.filePath);
    if (!candidate.hasSyncedLyrics &&
        current.synced != null &&
        current.synced!.isNotEmpty) {
      return LyricsFindResult(
        verdict: LyricsFindVerdict.keptExisting,
        best: candidate,
        bestConfidence: candidate.confidence,
        note: 'Le fichier a déjà des paroles calées : un résultat en '
            'texte seul ne les remplace pas.',
      );
    }
    final written = await _integrate(
      song: song,
      best: candidate,
      current: current,
      queriedTitle: queriedTitle.isEmpty ? song.title : queriedTitle,
      queriedArtist: queriedArtist.isEmpty ? song.artist : queriedArtist,
      viaFilename: false,
      origin: origin,
    );
    if (written == null) {
      return LyricsFindResult(
        verdict: LyricsFindVerdict.keptExisting,
        best: candidate,
        bestConfidence: candidate.confidence,
        note: 'Écriture impossible : sauvegarde ou accès refusé, '
            'rien n\'a été modifié.',
      );
    }
    return LyricsFindResult(
      verdict: LyricsFindVerdict.integrated,
      best: candidate,
      bestConfidence: candidate.confidence,
      replacedPrevious: _hasAnyLyrics(current),
      note: 'Paroles remplacées pour « ${song.title} » — ${song.artist}.',
    );
  }

  /// Diagnostiquer les paroles actuelles, sans rien écrire.
  Future<LyricsVerifyResult> verifyFor(Song song) async {
    final current = await _readCurrent(song.filePath);
    final currentProvenance = await provenance.forPath(song.filePath);
    final hasCurrent = _hasAnyLyrics(current);
    final find = await findFor(song, dryRun: true);

    if (!hasCurrent) {
      return LyricsVerifyResult(
        verdict: LyricsVerifyVerdict.unknown,
        message: 'Ce morceau n\'a pas de paroles dans son fichier.'
            '${find.best == null ? '' : ' Meilleur candidat : '
                '« ${find.best!.title} » — ${find.best!.artist} '
                '(confiance ${(find.bestConfidence * 100).round()} %).'}',
        find: find,
      );
    }

    if (currentProvenance?.isUserOrigin ?? false) {
      return LyricsVerifyResult(
        verdict: LyricsVerifyVerdict.protected,
        message: 'Paroles protégées : elles viennent de toi (collées, '
            'éditées ou calées à la main). Le diagnostic est donné, le '
            'remplacement n\'est que proposé.'
            '${find.best == null ? '' : ' Candidat : '
                '« ${find.best!.title} » — ${find.best!.artist} '
                '(confiance ${(find.bestConfidence * 100).round()} %).'}',
        find: find,
      );
    }

    final best = find.best;
    if (best != null &&
        best.confidence >= LyricsConfidence.autoIntegrateConfidence) {
      // Même enregistrement que l'actuel ? Même id LRCLIB, ou texte
      // identique à 90 %+ après pliage.
      final sameId =
          best.trackId != null && best.trackId == currentProvenance?.trackId;
      final sameText = _textSimilarity(
            _currentText(current),
            _candidateText(best),
          ) >=
          0.90;
      if (sameId || sameText) {
        return LyricsVerifyResult(
          verdict: LyricsVerifyVerdict.plausible,
          message: 'Paroles plausibles : elles correspondent à '
              '« ${best.title} » — ${best.artist} '
              '(confiance ${(best.confidence * 100).round()} %).',
          find: find,
        );
      }
      // Candidat sûr, texte différent, provenance auto basse ou absente
      // (ou texte seul actuel contre candidat synchro) : suspect.
      final weakProvenance =
          currentProvenance == null || currentProvenance.isLowConfidenceAuto;
      final plainVsSynced =
          (current.synced == null || current.synced!.isEmpty) &&
          best.hasSyncedLyrics;
      if (weakProvenance || plainVsSynced) {
        return LyricsVerifyResult(
          verdict: LyricsVerifyVerdict.suspicious,
          message: 'Ces paroles semblent être celles d\'un autre morceau : '
              'le meilleur candidat est « ${best.title} » — '
              '${best.artist} (source ${best.source}, confiance '
              '${(best.confidence * 100).round()} %).',
          find: find,
        );
      }
    }

    return LyricsVerifyResult(
      verdict: LyricsVerifyVerdict.plausible,
      message: 'Paroles plausibles : aucun candidat assez sûr ne les '
          'contredit.',
      find: find,
    );
  }

  // ---- décision ---------------------------------------------------------

  /// Null quand l'écriture peut avoir lieu, sinon le verdict de refus.
  LyricsFindVerdict? _decideWrite({
    required LyricsSearchResult best,
    required LyricsPair current,
    required LyricsProvenance? currentProvenance,
  }) {
    // Idempotent : un balayage répété ne doit pas réécrire des paroles
    // identiques et spammer l'Historique avec des écritures sans effet.
    final sameSynced = best.hasSyncedLyrics &&
        current.synced != null &&
        best.syncedLyrics!.toLrc() == current.synced!.toLrc();
    final samePlain = !best.hasSyncedLyrics &&
        current.unsynced != null &&
        best.unsyncedLyrics?.text == current.unsynced!.text;
    if (sameSynced || samePlain) return LyricsFindVerdict.keptExisting;
    // Paroles d'origine utilisateur : l'IA propose, ne remplace jamais seule.
    if (currentProvenance?.isUserOrigin ?? false) {
      return LyricsFindVerdict.needsChoice;
    }
    final hasSynced = current.synced != null && current.synced!.isNotEmpty;
    final hasPlain =
        current.unsynced != null && current.unsynced!.text.trim().isNotEmpty;
    // Texte seul sur du calé : jamais écraser.
    if (!best.hasSyncedLyrics && hasSynced) {
      return LyricsFindVerdict.keptExisting;
    }
    if (hasSynced && best.hasSyncedLyrics) {
      // Calé existant : on ne réécrit que ce que l'app a elle-même écrit
      // à basse confiance, ou ce qui date d'avant la provenance.
      if (currentProvenance == null || currentProvenance.isLowConfidenceAuto) {
        return null;
      }
      return LyricsFindVerdict.keptExisting;
    }
    if (!hasSynced && !hasPlain) return null; // rien : écrire.
    if (!hasSynced && hasPlain && best.hasSyncedLyrics) return null;
    // Texte seul existant, candidat texte seul : proposer, ne pas
    // remplacer une devinette par une autre sans voir.
    if (!hasSynced && hasPlain && !best.hasSyncedLyrics) {
      return LyricsFindVerdict.needsChoice;
    }
    return null;
  }

  String _keptNote(
    LyricsSearchResult best,
    LyricsPair current,
    LyricsProvenance? currentProvenance,
  ) {
    if (currentProvenance?.isUserOrigin ?? false) {
      return 'Ce morceau a déjà des paroles (protégées). Dis-moi '
          '« remplace-les par celles de ${best.title} » si tu veux que je '
          'les remplace.';
    }
    final hasSynced = current.synced != null && current.synced!.isNotEmpty;
    if (hasSynced && !best.hasSyncedLyrics) {
      return 'Le fichier a déjà des paroles calées : un résultat en '
          'texte seul ne les remplace pas.';
    }
    return 'Ce morceau a déjà des paroles synchronisées de confiance '
        'suffisante — gardées telles quelles.';
  }

  // ---- écriture ---------------------------------------------------------

  /// Écrit [best] dans le fichier (backup + Historique + provenance).
  ///
  /// Null quand l'écriture n'a pas eu lieu : pas d'accès, sauvegarde
  /// impossible (pas d'écriture silencieuse sans annulation possible),
  /// ou écriture non confirmée à la relecture. Dans ce dernier cas la
  /// sauvegarde n'est pas jetée (audit P11) : l'écriture partielle
  /// éventuelle reste annulable.
  Future<bool?> _integrate({
    required Song song,
    required LyricsSearchResult best,
    required LyricsPair current,
    required String queriedTitle,
    required String queriedArtist,
    required bool viaFilename,
    required LyricsProvenanceOrigin origin,
  }) async {
    if (!await hasWriteAccess()) return null;
    final canUndo = await backups.capture(song.filePath);
    if (!canUndo) return null;
    try {
      await repository.embedLyrics(
        song.filePath,
        synced: best.syncedLyrics,
        unsynced: best.unsyncedLyrics,
      );
    } catch (e, stack) {
      DebugLog.instance.error(
        'Paroles IA',
        'Échec de l\'écriture pour ${song.title}',
        error: e,
        stackTrace: stack,
      );
      await backups.discardLatest(song.filePath);
      return null;
    }
    await backups.markWritten(song.filePath);
    // Relecture : l'écriture n'est « écrite » que si les paroles sont
    // bien là et que l'audio n'a pas bougé (le writer vérifie déjà
    // l'offset ; ici on vérifie la présence des paroles).
    final after = await _readCurrent(song.filePath);
    final present = best.hasSyncedLyrics
        ? after.synced != null && after.synced!.isNotEmpty
        : after.unsynced != null && after.unsynced!.text.trim().isNotEmpty;
    if (!present) {
      DebugLog.instance.warning(
        'Paroles IA',
        'Écriture non confirmée à la relecture pour ${song.title}',
      );
      return null;
    }
    await provenance.record(
      song.filePath,
      LyricsProvenance(
        source: best.source,
        trackId: best.trackId,
        title: best.title,
        artist: best.artist,
        confidence: best.confidence,
        queryTitle: queriedTitle,
        queryArtist: queriedArtist,
        viaFilename: viaFilename,
        origin: origin,
        embeddedAt: DateTime.now(),
      ),
    );
    await provenance.save();
    fileChanged(song.filePath);
    return true;
  }

  Future<LyricsPair> _readCurrent(String filePath) async {
    try {
      return await repository.readLyrics(filePath);
    } catch (_) {
      // Illisible : on agit comme s'il n'y avait rien — l'écriture
      // tranchera, avec sa sauvegarde.
      return (synced: null, unsynced: null);
    }
  }

  static bool _hasAnyLyrics(LyricsPair pair) =>
      (pair.synced != null && pair.synced!.isNotEmpty) ||
      (pair.unsynced != null && pair.unsynced!.text.trim().isNotEmpty);

  static String _currentText(LyricsPair pair) {
    if (pair.synced != null && pair.synced!.isNotEmpty) {
      return pair.synced!.toLrc();
    }
    return pair.unsynced?.text ?? '';
  }

  static String _candidateText(LyricsSearchResult result) {
    if (result.hasSyncedLyrics) return result.syncedLyrics!.toLrc();
    return result.unsyncedLyrics?.text ?? '';
  }

  /// Similarité de deux textes de paroles, après pliage, en Dice sur
  /// les lignes : 1,0 = identiques. Les lignes sont assez distinctives
  /// pour qu'un faux positif soit rare.
  static double _textSimilarity(String a, String b) {
    final linesA = _foldedLines(a);
    final linesB = _foldedLines(b);
    if (linesA.isEmpty && linesB.isEmpty) return 1.0;
    if (linesA.isEmpty || linesB.isEmpty) return 0.0;
    final counts = <String, int>{};
    for (final line in linesA) {
      counts[line] = (counts[line] ?? 0) + 1;
    }
    var common = 0;
    for (final line in linesB) {
      final left = counts[line] ?? 0;
      if (left > 0) {
        counts[line] = left - 1;
        common++;
      }
    }
    return 2 * common / (linesA.length + linesB.length);
  }

  static List<String> _foldedLines(String text) => [
    for (final line in text.split('\n'))
      normalizeForConfidence(line.replaceAll(RegExp(r'^\[\d+:[\d.]+]'), '')),
  ].where((line) => line.isNotEmpty).toList();

  void _log(String verdict, Song song, double confidence, String query) {
    DebugLog.instance.info(
      'Paroles IA',
      '$verdict — ${song.title} (${(confidence * 100).round()} %, $query)',
    );
  }
}

/// Le service partagé, câblé sur les providers de l'app.
final aiLyricsFinderProvider = Provider<AiLyricsFinder>((ref) {
  final repository = ref.watch(lyricsRepositoryProvider);
  final provenance = ref.watch(lyricsProvenanceStoreProvider);
  final mismatchStore = ref.watch(lyricsMismatchStoreProvider);
  final backups = ref.watch(tagBackupStoreProvider);
  final changes = ref.watch(tagChangeProvider);
  final settings = ref.watch(aiSettingsProvider).valueOrNull;
  final filenameResolver = ref.watch(aiFilenameResolverProvider);
  return AiLyricsFinder(
    repository: repository,
    resolver: LyricsQueryResolver(
      readWithAi: settings == null || settings.usable.isEmpty
          ? null
          : (fileName) async {
              final resolution = await filenameResolver.resolve(
                settings: settings,
                fileName: fileName,
              );
              return resolution.guess;
            },
    ),
    provenance: provenance,
    backups: backups,
    mismatchStore: mismatchStore,
    fileChanged: changes.fileChanged,
  );
});
