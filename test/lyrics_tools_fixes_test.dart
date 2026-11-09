// Corrections lots G/K (scan DeepSeek) sur les outils de paroles :
// invalidation après écriture (G55), scope validé (K61), pluriel (K62),
// describeAction bornée comme execute (K63).
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/id3/tag_backup.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/tools/lyrics_tools.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/providers/backup_provider.dart';

Song _song() => Song(
  id: 1,
  title: 'Titre',
  artist: 'Artiste',
  album: '',
  duration: 180000,
  filePath: '/musique/1.mp3',
);

/// Faux lecteur : le morceau en cours est une variable, pas just_audio.
class _FakePlayer extends AudioPlayerService {
  Song? current;

  @override
  Song? get currentSong => current;
}

class _FakeRepo extends LyricsRepository {
  _FakeRepo() : super(sources: const []);

  int embeds = 0;

  @override
  Future<List<LyricsSearchResult>> searchAll({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
  }) async => [
    LyricsSearchResult(
      source: 'fake',
      title: title,
      artist: artist,
      syncedLyrics: SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
      ]),
      confidence: 0.9,
    ),
  ];

  @override
  Future<void> embedLyrics(
    String filePath, {
    SyncedLyrics? synced,
    UnsyncedLyrics? unsynced,
  }) async {
    embeds++;
  }

  @override
  Future<LyricsPair> readLyrics(String filePath) async => (
    synced: SyncedLyrics([
      const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
    ]),
    unsynced: null,
  );
}

final _refProbe = Provider<Ref>((ref) => ref);

AiToolContext _ctx(Ref ref) => AiToolContext(
  ref: ref,
  runTool: (_, _) async => AiToolResult.fail('non'),
  hasTool: (_) => false,
  requiresConfirmation: (_) => false,
);

void main() {
  // Le faux lecteur construit un vrai AudioPlayerService, dont le
  // constructeur touche aux method channels : sans binding, la
  // construction lève avant même le premier test.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('G55 — invalidation après écriture', () {
    test('fetch_lyrics invalide aussi le statut et le groupement', () async {
      final player = _FakePlayer()..current = _song();
      final repo = _FakeRepo();
      var statusBuilds = 0;
      var groupingBuilds = 0;
      final container = ProviderContainer(
        overrides: [
          audioPlayerServiceProvider.overrideWithValue(player),
          lyricsRepositoryProvider.overrideWithValue(repo),
          lyricsStatusProvider.overrideWith((ref) async {
            statusBuilds++;
            return <String, LyricsStatus>{};
          }),
          songsByStatusProvider.overrideWith((ref) {
            groupingBuilds++;
            return const AsyncValue<Map<LyricsStatus, List<Song>>>.loading();
          }),
        ],
      );
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));

      await container.read(lyricsStatusProvider.future);
      container.read(songsByStatusProvider);
      expect(statusBuilds, 1);
      expect(groupingBuilds, 1);

      final result = await const FetchLyricsTool().execute(ctx, {});
      expect(result.ok, isTrue);
      expect(repo.embeds, 1);

      await container.read(lyricsStatusProvider.future);
      container.read(songsByStatusProvider);
      expect(
        statusBuilds,
        2,
        reason: 'lyricsStatusProvider non invalidé après écriture',
      );
      expect(
        groupingBuilds,
        2,
        reason: 'songsByStatusProvider non invalidé après écriture',
      );
    });
  });

  group('K61 — scope validé', () {
    test('un scope inconnu est refusé, pas rabattu sur current', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));
      for (final tool in [
        const TrimEmptyLastLyricLineTool(),
        const CleanLyricsTool(),
        const ShiftLyricsTimestampsTool(),
        const RemoveLyricsTool(),
      ]) {
        await expectLater(
          tool.describeAction(ctx, {'scope': 'bogus', 'milliseconds': 100}),
          throwsA(isA<AiToolArgError>()),
        );
      }
    });

    test('execute refuse aussi le scope inconnu', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));
      await expectLater(
        const RemoveLyricsTool().execute(ctx, {'scope': 'All'}),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('les scopes valides passent la validation', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));
      // 'current' sans morceau en cours : l'erreur porte sur l'absence
      // de morceau, pas sur le scope — la validation a laissé passer.
      await expectLater(
        const TrimEmptyLastLyricLineTool().describeAction(ctx, {
          'scope': 'current',
        }),
        throwsA(
          isA<AiToolArgError>().having(
            (e) => e.message,
            'message',
            contains('Aucun morceau en cours.'),
          ),
        ),
      );
    });
  });

  group('K62 — pluriel', () {
    test('remove_lyrics : « 1 parole supprimée » au singulier', () async {
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final player = _FakePlayer()..current = _song();
      final container = ProviderContainer(
        overrides: [
          audioPlayerServiceProvider.overrideWithValue(player),
          lyricsRepositoryProvider.overrideWithValue(_FakeRepo()),
          tagBackupStoreProvider.overrideWithValue(TagBackupStore(root: dir)),
        ],
      );
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));

      final result = await const RemoveLyricsTool().execute(ctx, {});
      expect(result.ok, isTrue);
      expect(result.message, contains('1 parole supprimée'));
      expect(result.message, isNot(contains('1 paroles supprimées')));
    });
  });

  group('K63 — describeAction bornée', () {
    test('adjust_lyrics_offset montre la valeur bornée ±1000 ms', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));
      const tool = AdjustLyricsOffsetTool();
      expect(
        await tool.describeAction(ctx, {'milliseconds': 5000}),
        contains('+1000 ms'),
      );
      expect(
        await tool.describeAction(ctx, {'milliseconds': -5000}),
        contains('-1000 ms'),
      );
      expect(
        await tool.describeAction(ctx, {'milliseconds': 250}),
        contains('+250 ms'),
      );
    });
  });
}
