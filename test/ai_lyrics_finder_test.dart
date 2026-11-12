// Tests du service AiLyricsFinder (DESIGN.md §5, FILES.md §4.5 + §4.7).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/id3/tag_backup.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/data/ai_lyrics_finder.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_mismatch_store.dart';
import 'package:musync/features/lyrics/data/lyrics_provenance.dart';
import 'package:musync/features/lyrics/data/lyrics_query_resolver.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

Song _song({
  String title = 'Titre',
  String artist = 'Artiste',
  String album = '',
  int duration = 180000,
  String filePath = '/musique/1.mp3',
}) => Song(
  id: 1,
  title: title,
  artist: artist,
  album: album,
  duration: duration,
  filePath: filePath,
);

LyricsSearchResult _hit({
  String title = 'Titre',
  String artist = 'Artiste',
  String source = 'LRCLIB',
  int? trackId,
  int? durationMs = 180000,
  bool synced = true,
  String text = 'Vraies paroles',
}) => LyricsSearchResult(
  source: source,
  title: title,
  artist: artist,
  syncedLyrics: synced
      ? SyncedLyrics([
          LyricLine(timestamp: const Duration(seconds: 1), text: text),
        ])
      : null,
  unsyncedLyrics: synced ? null : UnsyncedLyrics(text),
  confidence: 0.0, // le finder rescore, la confiance d'entrée ne compte pas.
  trackId: trackId,
  durationMs: durationMs,
);

/// Faux dépôt avec état : ce qui est « écrit » est relu ensuite.
class _FakeRepo extends LyricsRepository {
  _FakeRepo() : super(sources: const []);

  /// Résultats rendus, par titre de requête.
  Map<String, List<LyricsSearchResult>> byQueryTitle = {};
  List<LyricsSearchResult> fallback = [];

  final Map<String, LyricsPair> files = {};
  final List<LyricsSearchResult> embedded = [];

  /// Le drapeau d'alignement reçu à chaque écriture, dans l'ordre.
  final List<bool> alignFlags = [];

  @override
  Future<List<LyricsSearchResult>> searchAll({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async => byQueryTitle[title] ?? fallback;

  @override
  Future<LyricsPair> readLyrics(String filePath) async =>
      files[filePath] ?? (synced: null, unsynced: null);

  @override
  Future<void> embedLyrics(
    String filePath, {
    SyncedLyrics? synced,
    UnsyncedLyrics? unsynced,
    bool alignToExisting = false,
  }) async {
    alignFlags.add(alignToExisting);
    embedded.add(
      LyricsSearchResult(
        source: 'LRCLIB',
        title: '',
        artist: '',
        syncedLyrics: synced,
        unsyncedLyrics: unsynced,
        confidence: 1.0,
      ),
    );
    files[filePath] = (synced: synced, unsynced: unsynced);
  }
}

void main() {
  late Directory tmp;
  late Directory root;
  late _FakeRepo repo;
  late LyricsProvenanceStore provenance;
  late TagBackupStore backups;
  late List<String> changed;

  AiLyricsFinder finder({LyricsQueryResolver? resolver}) => AiLyricsFinder(
    repository: repo,
    resolver:
        resolver ??
        const LyricsQueryResolver(parseFilename: _noGuess),
    provenance: provenance,
    backups: backups,
    mismatchStore: LyricsMismatchStore(root: root),
    fileChanged: changed.add,
    hasWriteAccess: () async => true,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ai_lyrics_finder_');
    root = Directory('${tmp.path}/support')..createSync();
    repo = _FakeRepo();
    provenance = LyricsProvenanceStore(root: root);
    backups = TagBackupStore(root: root);
    changed = [];
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // Un vrai fichier (vide, sans tag) pour que capture() réussisse.
  Future<String> realFile(String name) async {
    final file = File('${tmp.path}/$name');
    await file.create();
    return file.path;
  }

  test('≥ 0,80 + pas de paroles → écriture + provenance + invalidation', () async {
    final path = await realFile('1.mp3');
    repo.fallback = [_hit(trackId: 7)];
    final result = await finder().findFor(_song(filePath: path));
    expect(result.verdict, LyricsFindVerdict.integrated);
    // 0,35 + 0,30 + 0,15 (durée) + 0,05 (synchro), sans album.
    expect(result.bestConfidence, closeTo(0.85, 0.001));
    expect(repo.embedded, hasLength(1));
    expect(repo.alignFlags, [false]);
    expect(changed, [path]);
    final recorded = await provenance.forPath(path);
    expect(recorded, isNotNull);
    expect(recorded!.trackId, 7);
    expect(recorded.confidence, closeTo(0.85, 0.001));
    expect(recorded.origin, LyricsProvenanceOrigin.autoAi);
  });

  test('candidat LyricsPlus ≥ 0,80 → écriture avec alignement', () async {
    final path = await realFile('1b.mp3');
    repo.fallback = [_hit(trackId: 7, source: 'LyricsPlus')];
    final result = await finder().findFor(_song(filePath: path));
    expect(result.verdict, LyricsFindVerdict.integrated);
    expect(repo.embedded, hasLength(1));
    expect(repo.alignFlags, [true]);
  });

  test('0,50–0,79 → rien d\'écrit, verdict needsChoice, top 3 rendu', () async {
    final path = await realFile('1.mp3');
    repo.fallback = [
      _hit(title: 'Titre', artist: 'Autre Artiste', trackId: 1),
    ];
    final result = await finder().findFor(_song(filePath: path));
    expect(result.verdict, LyricsFindVerdict.needsChoice);
    // 0,35 (titre) + 0,15 (artiste partiel) + 0,15 (durée) + 0,05 (synchro).
    expect(result.bestConfidence, closeTo(0.70, 0.001));
    expect(repo.embedded, isEmpty);
    expect(result.top, hasLength(1));
  });

  test('< 0,50 → rien d\'écrit, verdict notFound', () async {
    final path = await realFile('1.mp3');
    repo.fallback = [
      _hit(title: 'Autre', artist: 'Autre Artiste', trackId: 1),
    ];
    final result = await finder().findFor(_song(filePath: path));
    expect(result.verdict, LyricsFindVerdict.notFound);
    expect(repo.embedded, isEmpty);
  });

  test('paroles utilisateur + candidat 0,95 → rien d\'écrit, proposition', () async {
    final path = await realFile('1.mp3');
    repo.files[path] = (
      synced: SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'Mes paroles'),
      ]),
      unsynced: null,
    );
    await provenance.record(
      path,
      LyricsProvenance(
        source: 'utilisateur',
        title: 'Titre',
        artist: 'Artiste',
        confidence: 1.0,
        queryTitle: '',
        queryArtist: '',
        viaFilename: false,
        origin: LyricsProvenanceOrigin.pasted,
        embeddedAt: DateTime.now(),
      ),
    );
    repo.fallback = [_hit(trackId: 7)];
    final result = await finder().findFor(_song(filePath: path));
    expect(result.verdict, LyricsFindVerdict.needsChoice);
    expect(repo.embedded, isEmpty);
  });

  test('candidat texte seul + fichier calé → rien d\'écrit', () async {
    final path = await realFile('1.mp3');
    repo.files[path] = (
      synced: SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'Calées'),
      ]),
      unsynced: null,
    );
    repo.fallback = [_hit(synced: false, trackId: 7)];
    final result = await finder().findFor(_song(filePath: path));
    expect(result.verdict, LyricsFindVerdict.keptExisting);
    expect(repo.embedded, isEmpty);
  });

  test('sans backup possible → pas d\'écriture silencieuse', () async {
    // Fichier inexistant : capture() répond faux.
    repo.fallback = [_hit(trackId: 7)];
    final result = await finder().findFor(_song(filePath: '/nulle/part/1.mp3'));
    expect(result.verdict, LyricsFindVerdict.keptExisting);
    expect(repo.embedded, isEmpty);
  });

  test('paroles calées auto basse confiance → réécrites quand mieux', () async {
    final path = await realFile('1.mp3');
    repo.files[path] = (
      synced: SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'Fausses'),
      ]),
      unsynced: null,
    );
    await provenance.record(
      path,
      LyricsProvenance(
        source: 'LRCLIB',
        trackId: 1,
        title: 'Titre',
        artist: 'Artiste',
        confidence: 0.40,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
        viaFilename: false,
        origin: LyricsProvenanceOrigin.autoBackground,
        embeddedAt: DateTime.now(),
      ),
    );
    repo.fallback = [_hit(trackId: 7)];
    final result = await finder().findFor(_song(filePath: path));
    expect(result.verdict, LyricsFindVerdict.integrated);
    expect(result.replacedPrevious, isTrue);
  });

  test('paroles calées auto haute confiance → gardées', () async {
    final path = await realFile('1.mp3');
    repo.files[path] = (
      synced: SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'Bonnes'),
      ]),
      unsynced: null,
    );
    await provenance.record(
      path,
      LyricsProvenance(
        source: 'LRCLIB',
        trackId: 7,
        title: 'Titre',
        artist: 'Artiste',
        confidence: 0.93,
        queryTitle: 'Titre',
        queryArtist: 'Artiste',
        viaFilename: false,
        origin: LyricsProvenanceOrigin.autoAi,
        embeddedAt: DateTime.now(),
      ),
    );
    repo.fallback = [_hit(trackId: 7)];
    final result = await finder().findFor(_song(filePath: path));
    expect(result.verdict, LyricsFindVerdict.keptExisting);
    expect(repo.embedded, isEmpty);
  });

  group('verifyFor', () {
    test('candidat 0,90 + texte différent + provenance auto 0,40 → suspectes', () async {
      final path = await realFile('1.mp3');
      repo.files[path] = (
        synced: SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'Fausses'),
        ]),
        unsynced: null,
      );
      await provenance.record(
        path,
        LyricsProvenance(
          source: 'LRCLIB',
          trackId: 1,
          title: 'Titre',
          artist: 'Artiste',
          confidence: 0.40,
          queryTitle: 'Titre',
          queryArtist: 'Artiste',
          viaFilename: false,
          origin: LyricsProvenanceOrigin.autoBackground,
          embeddedAt: DateTime.now(),
        ),
      );
      repo.fallback = [_hit(trackId: 7, text: 'Vraies paroles')];
      final verdict = await finder().verifyFor(_song(filePath: path));
      expect(verdict.verdict, LyricsVerifyVerdict.suspicious);
      expect(repo.embedded, isEmpty); // lecture seule.
    });

    test('même id LRCLIB → plausibles', () async {
      final path = await realFile('1.mp3');
      repo.files[path] = (
        synced: SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'Vraies paroles'),
        ]),
        unsynced: null,
      );
      await provenance.record(
        path,
        LyricsProvenance(
          source: 'LRCLIB',
          trackId: 7,
          title: 'Titre',
          artist: 'Artiste',
          confidence: 0.93,
          queryTitle: 'Titre',
          queryArtist: 'Artiste',
          viaFilename: false,
          origin: LyricsProvenanceOrigin.autoAi,
          embeddedAt: DateTime.now(),
        ),
      );
      repo.fallback = [_hit(trackId: 7, text: 'Vraies paroles')];
      final verdict = await finder().verifyFor(_song(filePath: path));
      expect(verdict.verdict, LyricsVerifyVerdict.plausible);
    });

    test('origine user → protégées, diagnostic rendu sans écriture', () async {
      final path = await realFile('1.mp3');
      repo.files[path] = (
        synced: null,
        unsynced: const UnsyncedLyrics('Mes paroles'),
      );
      await provenance.record(
        path,
        LyricsProvenance(
          source: 'utilisateur',
          title: 'Titre',
          artist: 'Artiste',
          confidence: 1.0,
          queryTitle: '',
          queryArtist: '',
          viaFilename: false,
          origin: LyricsProvenanceOrigin.editor,
          embeddedAt: DateTime.now(),
        ),
      );
      repo.fallback = [_hit(trackId: 7)];
      final verdict = await finder().verifyFor(_song(filePath: path));
      expect(verdict.verdict, LyricsVerifyVerdict.protected);
      expect(repo.embedded, isEmpty);
    });

    test('pas de paroles dans le fichier + candidat sûr → trouvé en ligne, rien écrit', () async {
      final path = await realFile('1.mp3');
      repo.fallback = [_hit(trackId: 7)];
      final verdict = await finder().verifyFor(_song(filePath: path));
      expect(verdict.verdict, LyricsVerifyVerdict.unknown);
      expect(verdict.message, contains('Trouvé en ligne'));
      expect(verdict.message, contains('« Titre »'));
      expect(repo.embedded, isEmpty);
    });

    test('pas de paroles dans le fichier + rien trouvé → « rien trouvé en ligne »', () async {
      final path = await realFile('1.mp3');
      repo.fallback = [];
      final verdict = await finder().verifyFor(_song(filePath: path));
      expect(verdict.verdict, LyricsVerifyVerdict.unknown);
      expect(
        verdict.message,
        contains('Aucune parole trouvée en ligne'),
      );
      expect(repo.embedded, isEmpty);
    });

    test('pas de paroles + candidat à 0,65 → la liste est présentée', () async {
      final path = await realFile('1.mp3');
      // Titre partiel 0,15 + artiste 0,30 + durée 0,15 + synchro 0,05.
      repo.fallback = [_hit(title: 'Autre titre')];
      final verdict = await finder().verifyFor(_song(filePath: path));
      expect(verdict.verdict, LyricsVerifyVerdict.unknown);
      expect(verdict.message, contains('Plusieurs candidats possibles'));
      expect(verdict.message, contains('1. « Autre titre »'));
      expect(repo.embedded, isEmpty);
    });

    test('pas de paroles + morceau marqué → la recherche tourne quand même', () async {
      final path = await realFile('1.mp3');
      final marked = LyricsMismatchStore(root: root);
      await marked.markMismatched(path, title: 'Titre', artist: 'Artiste');
      await marked.save();
      final markedFinder = AiLyricsFinder(
        repository: repo,
        resolver: const LyricsQueryResolver(parseFilename: _noGuess),
        provenance: provenance,
        backups: backups,
        mismatchStore: marked,
        fileChanged: changed.add,
        hasWriteAccess: () async => true,
      );
      repo.fallback = [_hit(trackId: 7)];
      final verdict = await markedFinder.verifyFor(_song(filePath: path));
      expect(verdict.verdict, LyricsVerifyVerdict.unknown);
      expect(verdict.message, contains('Trouvé en ligne'));
      expect(repo.embedded, isEmpty);
    });
  });

  test('sources injoignables → notFound avec searchesFailed, rien mémorisé', () async {
    final path = await realFile('1.mp3');
    final failing = _ThrowingRepo();
    final failingFinder = AiLyricsFinder(
      repository: failing,
      resolver: const LyricsQueryResolver(parseFilename: _noGuess),
      provenance: provenance,
      backups: backups,
      mismatchStore: LyricsMismatchStore(root: root),
      fileChanged: changed.add,
      hasWriteAccess: () async => true,
    );
    final result = await failingFinder.findFor(_song(filePath: path));
    expect(result.verdict, LyricsFindVerdict.notFound);
    expect(result.searchesFailed, isTrue);
    expect(failing.embeds, 0);
  });

  test('paroles identiques déjà dans le fichier → pas de réécriture', () async {
    final path = await realFile('1.mp3');
    repo.files[path] = (
      synced: SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'Vraies paroles'),
      ]),
      unsynced: null,
    );
    repo.fallback = [_hit(trackId: 7, text: 'Vraies paroles')];
    final result = await finder().findFor(_song(filePath: path));
    expect(result.verdict, LyricsFindVerdict.keptExisting);
    expect(repo.embedded, isEmpty);
  });

  test('scénario doré : tags « 09 », fichier « Artiste Réel - Vrai Titre »', () async {
    final path = await realFile('Artiste Réel - Vrai Titre (Official Video).mp3');
    repo.byQueryTitle = {
      '09': [
        _hit(title: '09', artist: 'Autre Artiste', trackId: 1),
      ],
      'Vrai Titre': [
        _hit(title: 'Vrai Titre', artist: 'Artiste Réel', trackId: 2),
      ],
    };
    final resolver = LyricsQueryResolver(
      parseFilename: (_) => (artist: 'Artiste Réel', title: 'Vrai Titre'),
    );
    final result = await finder(resolver: resolver).findFor(
      _song(title: '09', artist: 'Artiste inconnu', filePath: path),
    );
    // Le bon hit à 0,95 gagne, le faux à 0,55 n'est jamais écrit.
    expect(result.verdict, LyricsFindVerdict.integrated);
    expect(result.bestConfidence, closeTo(0.95, 0.001));
    expect(result.best?.trackId, 2);
    expect(result.viaFilename, isTrue);
    expect(repo.embedded, hasLength(1));
    final recorded = await provenance.forPath(path);
    expect(recorded!.trackId, 2);
    expect(recorded.viaFilename, isTrue);
  });
}

/// Dépôt dont toutes les recherches échouent (sources injoignables).
class _ThrowingRepo extends LyricsRepository {
  _ThrowingRepo() : super(sources: const []);

  int embeds = 0;

  @override
  Future<List<LyricsSearchResult>> searchAll({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async => throw const LyricsSourceException('LRCLIB', 'injoignable');

  @override
  Future<void> embedLyrics(
    String filePath, {
    SyncedLyrics? synced,
    UnsyncedLyrics? unsynced,
    bool alignToExisting = false,
  }) async {
    embeds++;
  }
}

FilenameGuess _noGuess(String _) => (artist: '', title: '');
