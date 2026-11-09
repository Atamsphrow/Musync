/// Tests F47 (scan DeepSeek, lot F) : le shuffle doit mélanger AVANT de
/// lancer la lecture, sinon le premier morceau est toujours le même.
///
/// - `play_artist_shuffled` : la file jouée est une permutation des
///   correspondances, et le premier morceau varie d'un appel à l'autre.
/// - `create_named_queue` avec `shuffled: true` : la lecture est mélangée,
///   mais la file nommée sauvegardée garde l'ordre d'origine.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/ai_tool_registry.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/named_queue_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

AiToolContext _ctx(Ref ref) => AiToolContext(
      ref: ref,
      runTool: (_, _) async => AiToolResult.fail('non'),
      hasTool: (_) => false,
      requiresConfirmation: (_) => false,
    );

final _refProbe = Provider<Ref>((ref) => ref);

Song _song(int id, String title, String artist) => Song(
      id: id,
      title: title,
      artist: artist,
      album: '',
      duration: 200000,
      filePath: '/x/$id.mp3',
    );

class _FakeSongList extends SongListNotifier {
  final List<Song> songs;
  _FakeSongList(this.songs);

  @override
  Future<List<Song>> build() async => songs;
}

/// Lecteur enregistreur : note la file passée à `playSong` et les appels à
/// `toggleShuffle`, sans toucher à l'audio.
class _RecordingPlayer extends AudioPlayerService {
  List<Song>? playedQueue;
  Song? playedSong;
  int toggleShuffleCalls = 0;
  bool shuffleEnabled = false;

  @override
  bool get isShuffleEnabled => shuffleEnabled;

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    Duration? fadeIn,
  }) async {
    playedSong = song;
    playedQueue = queue;
  }

  @override
  Future<void> toggleShuffle() async {
    toggleShuffleCalls++;
    shuffleEnabled = true;
  }
}

void main() {
  // Le faux lecteur hérite d'AudioPlayerService : le binding doit exister
  // avant sa construction.
  TestWidgetsFlutterBinding.ensureInitialized();

  final artistSongs = [
    _song(1, 'A', 'Billie Eilish'),
    _song(2, 'B', 'Billie Eilish'),
    _song(3, 'C', 'Billie Eilish'),
    _song(4, 'D', 'Billie Eilish'),
    _song(5, 'E', 'Billie Eilish'),
  ];

  ProviderContainer makeContainer(
    List<Song> songs,
    _RecordingPlayer player,
  ) {
    final container = ProviderContainer(
      overrides: [
        songListProvider.overrideWith(() => _FakeSongList(songs)),
        audioPlayerServiceProvider.overrideWithValue(player),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('play_artist_shuffled', () {
    test('la file jouée est mélangée, pas l’ordre de la bibliothèque',
        () async {
      final player = _RecordingPlayer();
      final container = makeContainer(artistSongs, player);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['play_artist_shuffled']!;
      final result = await tool.execute(ctx, {'artist': 'Billie Eilish'});
      expect(result.ok, isTrue);
      expect(player.playedQueue, isNotNull);
      // Une permutation des correspondances — jamais la liste d'origine.
      expect(player.playedQueue, unorderedEquals(artistSongs));
      expect(identical(player.playedQueue, artistSongs), isFalse);
      expect(player.playedSong, player.playedQueue!.first);
      expect(player.toggleShuffleCalls, 1);
    });

    test('le premier morceau varie d’un appel à l’autre', () async {
      // Un seul tirage pourrait retomber sur l'ordre d'origine (1/120
      // avec 5 morceaux) : on répète 30 fois. Sans le correctif, le
      // premier morceau est toujours le premier de la bibliothèque.
      final firstIds = <int>{};
      for (var i = 0; i < 30; i++) {
        final player = _RecordingPlayer();
        final container = makeContainer(artistSongs, player);
        final ctx = _ctx(container.read(_refProbe));
        final tool = buildAiToolRegistry()['play_artist_shuffled']!;
        final result = await tool.execute(ctx, {'artist': 'Billie Eilish'});
        expect(result.ok, isTrue);
        firstIds.add(player.playedSong!.id);
      }
      expect(firstIds.length, greaterThan(1));
    });
  });

  group('create_named_queue shuffled', () {
    test('la file sauvegardée garde l’ordre d’origine', () async {
      SharedPreferences.setMockInitialValues({});
      final player = _RecordingPlayer();
      final container = makeContainer(artistSongs, player);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['create_named_queue']!;
      final result = await tool.execute(ctx, {
        'name': 'Billie mix',
        'query': 'Billie Eilish',
        'shuffled': true,
      });
      expect(result.ok, isTrue);
      // La lecture est mélangée…
      expect(player.playedQueue, unorderedEquals(artistSongs));
      expect(identical(player.playedQueue, artistSongs), isFalse);
      expect(player.toggleShuffleCalls, 1);
      // …mais la file nommée, elle, garde l’ordre d’origine (la file par
      // défaut est toujours présente en plus de celle créée).
      final saved = container.read(namedQueuesProvider).queues;
      final created = saved.singleWhere((q) => q.name == 'Billie mix');
      expect(created.songs, orderedEquals(artistSongs));
    });
  });
}
