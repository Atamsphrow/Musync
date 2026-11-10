// Outils IA paroles, mode IA (DESIGN.md §7, FILES.md §4.6) : seuil 0,80,
// pas d'écriture en dessous, message avec la confiance en %, confirmation
// pour replace_lyrics, verify_current_lyrics en lecture seule, lot avec
// backup + Historique.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/id3/tag_backup.dart';
import 'package:musync/core/router/app_router.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/tools/lyrics_tools.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/lyrics/data/ai_lyrics_finder.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_mismatch_store.dart';
import 'package:musync/features/lyrics/data/lyrics_provenance.dart';
import 'package:musync/features/lyrics/data/lyrics_query_resolver.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/providers/backup_provider.dart';

Song _song({
  String title = 'Titre',
  String artist = 'Artiste',
  String album = '',
  int duration = 180000,
  required String filePath,
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
  int? trackId,
  int? durationMs = 180000,
  bool synced = true,
  String text = 'Vraies paroles',
  double confidence = 0.0, // le finder rescore, la confiance d'entrée ne compte pas.
}) => LyricsSearchResult(
  source: 'LRCLIB',
  title: title,
  artist: artist,
  syncedLyrics: synced
      ? SyncedLyrics([
          LyricLine(timestamp: const Duration(seconds: 1), text: text),
        ])
      : null,
  unsyncedLyrics: synced ? null : UnsyncedLyrics(text),
  confidence: confidence,
  trackId: trackId,
  durationMs: durationMs,
);

/// Faux lecteur : le morceau en cours est une variable, pas just_audio.
class _FakePlayer extends AudioPlayerService {
  Song? current;

  @override
  Song? get currentSong => current;
}

/// Faux dépôt avec état : ce qui est « écrit » est relu ensuite.
class _FakeRepo extends LyricsRepository {
  _FakeRepo() : super(sources: const []);

  /// Résultats rendus, par titre de requête.
  Map<String, List<LyricsSearchResult>> byQueryTitle = {};
  List<LyricsSearchResult> fallback = [];

  final Map<String, LyricsPair> files = {};
  final List<LyricsSearchResult> embedded = [];

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
  }) async {
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

FilenameGuess _noGuess(String _) => (artist: '', title: '');

final _refProbe = Provider<Ref>((ref) => ref);

AiToolContext _ctx(Ref ref) => AiToolContext(
  ref: ref,
  runTool: (_, _) async => AiToolResult.fail('non'),
  hasTool: (_) => false,
  requiresConfirmation: (_) => false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory root;
  late _FakeRepo repo;
  late LyricsProvenanceStore provenance;
  late TagBackupStore backups;
  late List<String> changed;
  late _FakePlayer player;

  AiLyricsFinder finder() => AiLyricsFinder(
    repository: repo,
    resolver: const LyricsQueryResolver(parseFilename: _noGuess),
    provenance: provenance,
    backups: backups,
    mismatchStore: LyricsMismatchStore(root: root),
    fileChanged: changed.add,
    hasWriteAccess: () async => true,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lyrics_tools_conf_');
    root = Directory('${tmp.path}/support')..createSync();
    repo = _FakeRepo();
    provenance = LyricsProvenanceStore(root: root);
    backups = TagBackupStore(root: root);
    changed = [];
    player = _FakePlayer();
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

  ProviderContainer container({
    Map<LyricsStatus, List<Song>> byStatus = const {},
  }) {
    final c = ProviderContainer(
      overrides: [
        audioPlayerServiceProvider.overrideWithValue(player),
        lyricsRepositoryProvider.overrideWithValue(repo),
        aiLyricsFinderProvider.overrideWithValue(finder()),
        tagBackupStoreProvider.overrideWithValue(backups),
        lyricsProvenanceStoreProvider.overrideWithValue(provenance),
        lyricsStatusProvider.overrideWith(
          (ref) async => <String, LyricsStatus>{},
        ),
        songsByStatusProvider.overrideWith(
          (ref) => AsyncValue.data(byStatus),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('fetch_lyrics — seuil 0,80', () {
    test('sous 0,80 : rien n\'est écrit, le message donne la confiance', () async {
      final path = await realFile('1.mp3');
      player.current = _song(filePath: path);
      // Titre partiel (« Autre titre » contient « titre ») 0,15 +
      // artiste 0,30 + durée 0,15 + synchro 0,05 = 0,65.
      repo.fallback = [_hit(title: 'Autre titre')];
      final c = container();
      final result = await const FetchLyricsTool().execute(
        _ctx(c.read(_refProbe)),
        const {},
      );

      expect(result.ok, isTrue);
      expect(result.message, contains('65 %'));
      expect(result.navigateTo, AppRoutes.lyricsSearch);
      expect(repo.embedded, isEmpty);
      expect(await provenance.forPath(path), isNull);
      expect(await backups.list(), isEmpty);
    });

    test('à 0,85 : écriture avec backup + provenance + invalidation', () async {
      final path = await realFile('1.mp3');
      player.current = _song(filePath: path);
      repo.fallback = [_hit(trackId: 7)];
      final c = container();
      final result = await const FetchLyricsTool().execute(
        _ctx(c.read(_refProbe)),
        const {},
      );

      expect(result.ok, isTrue);
      expect(result.message, contains('85 %'));
      expect(repo.embedded, hasLength(1));
      expect(
        (await backups.list()).any((e) => e.filePath == path),
        isTrue,
      );
      final entry = await provenance.forPath(path);
      expect(entry, isNotNull);
      expect(entry!.confidence, 0.85);
      expect(entry.trackId, 7);
      expect(entry.origin, LyricsProvenanceOrigin.autoAi);
      expect(changed, contains(path));
    });
  });

  group('verify_current_lyrics — lecture seule', () {
    test('paroles plausibles : rien n\'est écrit', () async {
      final path = await realFile('1.mp3');
      player.current = _song(filePath: path);
      repo.files[path] = (
        synced: SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'Vraies paroles'),
        ]),
        unsynced: null,
      );
      repo.fallback = [_hit(trackId: 7)];
      final c = container();
      final result = await const VerifyCurrentLyricsTool().execute(
        _ctx(c.read(_refProbe)),
        const {},
      );

      expect(result.ok, isTrue);
      expect(result.message, contains('plausibles'));
      expect(repo.embedded, isEmpty);
      expect(await backups.list(), isEmpty);
      expect(await provenance.forPath(path), isNull);
    });
  });

  group('replace_lyrics — remplacement explicite', () {
    test('confirmation requise et dialogue décrivant le remplacement', () async {
      final path = await realFile('1.mp3');
      player.current = _song(filePath: path);
      repo.fallback = [_hit(trackId: 7)];
      final c = container();
      final tool = const ReplaceLyricsTool();

      expect(tool.requiresConfirmation, isTrue);
      final description = await tool.describeAction(
        _ctx(c.read(_refProbe)),
        const {},
      );
      expect(description, contains('« Titre »'));
      expect(description, contains('aucune parole'));
      expect(description, contains('85 %'));
    });

    test('exécute le remplacement au rang 1, refuse un rang inexistant', () async {
      final path = await realFile('1.mp3');
      player.current = _song(filePath: path);
      repo.fallback = [_hit(trackId: 7)];
      final c = container();
      final ctx = _ctx(c.read(_refProbe));
      final tool = const ReplaceLyricsTool();

      final done = await tool.execute(ctx, const {});
      expect(done.ok, isTrue);
      expect(done.message, contains('remplacées'));
      expect(repo.embedded, hasLength(1));

      final bad = await tool.execute(ctx, const {'rank': 2});
      expect(bad.ok, isFalse);
      expect(bad.message, contains('Rang 2 inexistant'));
      expect(repo.embedded, hasLength(1));
    });
  });

  group('batch_fetch_lyrics — seuil + backup + Historique', () {
    test('0,90 intégré avec backup, 0,60 laissé à la revue', () async {
      final path1 = await realFile('1.mp3');
      final path2 = await realFile('2.mp3');
      final song1 = _song(filePath: path1);
      final song2 = _song(title: 'Titre 2', filePath: path2);
      repo.byQueryTitle['Titre'] = [_hit(confidence: 0.9)];
      repo.byQueryTitle['Titre 2'] = [_hit(confidence: 0.6)];
      final c = container(
        byStatus: {
          LyricsStatus.none: [song1, song2],
        },
      );

      final result = await const BatchFetchLyricsTool().execute(
        _ctx(c.read(_refProbe)),
        const {},
      );

      expect(result.ok, isTrue);
      expect(result.message, contains('1 morceau'));
      expect(repo.embedded, hasLength(1));
      // Backup + Historique pour le morceau intégré.
      expect(
        (await backups.list()).any((e) => e.filePath == path1),
        isTrue,
      );
      final history = await c.read(tagBackupsProvider.future);
      expect(history.any((e) => e.filePath == path1), isTrue);
      final entry = await provenance.forPath(path1);
      expect(entry, isNotNull);
      expect(entry!.origin, LyricsProvenanceOrigin.batch);
      expect(entry.confidence, 0.9);
      // Le morceau à 0,60 n'a ni écriture ni provenance.
      expect(await provenance.forPath(path2), isNull);
    });
  });
}
