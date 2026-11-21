// The listening history: what counts as a listen, how it is stored, and
// the two orders the « Historique » view shows.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musync/features/library/data/listening_history_store.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/listening_history_provider.dart';
import 'package:musync/features/player/data/audio_player_service.dart';

Song _song(int id) => Song(
      id: id,
      title: 'T$id',
      artist: 'A',
      album: 'B',
      duration: 200000,
      filePath: '/music/$id.mp3',
    );

/// Feeds the recorder by hand: the current track, positions, loop wraps.
class _FakePlayer extends AudioPlayerService {
  final songs = StreamController<Song?>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  final discontinuities = StreamController<PositionDiscontinuity>.broadcast();
  Song? current;

  @override
  Song? get currentSong => current;

  @override
  Stream<Song?> get currentSongStream => songs.stream;

  @override
  Stream<Duration> get positionStream => positions.stream;

  @override
  Stream<PositionDiscontinuity> get positionDiscontinuityStream =>
      discontinuities.stream;

  @override
  bool get isPlaying => true;

  Future<void> emitSong(Song song) async {
    current = song;
    songs.add(song);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> at(int seconds) async {
    positions.add(Duration(seconds: seconds));
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> loopOne() async {
    discontinuities.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.autoAdvance,
        PlaybackEvent(currentIndex: 0),
        PlaybackEvent(currentIndex: 0),
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the recorder', () {
    late _FakePlayer player;
    late List<String> recorded;
    late ListeningHistoryRecorder recorder;

    setUp(() {
      player = _FakePlayer();
      recorded = [];
      recorder = ListeningHistoryRecorder(player, (path) async {
        recorded.add(path);
      })
        ..start();
    });

    tearDown(() async {
      recorder.stop();
      await player.songs.close();
      await player.positions.close();
      await player.discontinuities.close();
    });

    test('counts one listen per pass of the threshold', () async {
      await player.emitSong(_song(1));
      await player.at(10);
      await player.at(31);
      await player.at(60);
      expect(recorded, ['/music/1.mp3']);
    });

    test('repeat-one: every loop past the threshold is a listen', () async {
      await player.emitSong(_song(1));
      await player.at(31);
      await player.loopOne();
      await player.at(31);
      await player.loopOne();
      await player.at(31);
      expect(recorded, List.filled(3, '/music/1.mp3'));
    });

    test('back to the start of the same track: a new listen', () async {
      await player.emitSong(_song(1));
      await player.at(40);
      await player.at(0); // Replayed, or a one-track queue looping.
      await player.at(35);
      expect(recorded, List.filled(2, '/music/1.mp3'));
    });

    test('a seek back mid-track is not a new listen', () async {
      await player.emitSong(_song(1));
      await player.at(40);
      await player.at(20);
      await player.at(45);
      expect(recorded, ['/music/1.mp3']);
    });

    test('renamed while playing: the listen lands on the new path', () async {
      await player.emitSong(_song(1));
      await player.at(10);
      await player.emitSong(_song(1).copyWith(filePath: '/music/new.mp3'));
      await player.at(31);
      expect(recorded, ['/music/new.mp3']);
    });

    test('a very short track is counted once per pass', () async {
      final short = _song(2).copyWith(duration: 4000); // Threshold: 2 s.
      await player.emitSong(short);
      await player.at(2);
      await player.at(2);
      await player.at(3);
      expect(recorded, ['/music/2.mp3']);
    });
  });

  test('a listen is 30 s, or half of a track under a minute', () {
    expect(listenThreshold(const Duration(minutes: 4)),
        const Duration(seconds: 30));
    expect(listenThreshold(const Duration(seconds: 40)),
        const Duration(seconds: 20));
    expect(listenThreshold(Duration.zero), const Duration(seconds: 30));
  });

  test('the store round-trips and skips malformed entries', () async {
    final dir = await Directory.systemTemp.createTemp('musync_history_');
    addTearDown(() => dir.delete(recursive: true));
    final store = ListeningHistoryStore(root: dir);
    await store.save({
      '/a.mp3': const ListenEntry(count: 3, lastPlayedMs: 10),
    });
    expect(await store.load(), {
      '/a.mp3': const ListenEntry(count: 3, lastPlayedMs: 10),
    });

    await File('${dir.path}/listening_history.json').writeAsString(
      '{"/a.mp3": {"count": 2, "last": 5}, "/b.mp3": {"count": "x"}}',
    );
    expect((await store.load()).keys, ['/a.mp3']);
  });

  test('recent by last listen, most played by count', () {
    final songs = [_song(1), _song(2), _song(3)];
    final history = {
      '/music/1.mp3': const ListenEntry(count: 5, lastPlayedMs: 100),
      '/music/2.mp3': const ListenEntry(count: 1, lastPlayedMs: 300),
      '/gone.mp3': const ListenEntry(count: 9, lastPlayedMs: 999),
    };
    expect(
      historySongs(songs, history, byCount: false).map((s) => s.id),
      [2, 1],
    );
    expect(
      historySongs(songs, history, byCount: true).map((s) => s.id),
      [1, 2],
    );
  });

  test('listens recorded before the file loads are not lost', () async {
    final dir = await Directory.systemTemp.createTemp('musync_history_');
    addTearDown(() => dir.delete(recursive: true));
    await ListeningHistoryStore(root: dir).save({
      '/a.mp3': const ListenEntry(count: 1, lastPlayedMs: 1),
    });
    final container = ProviderContainer(
      overrides: [
        listeningHistoryStoreProvider.overrideWithValue(
          ListeningHistoryStore(root: dir),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(listeningHistoryProvider.notifier);
    await notifier.record('/a.mp3', atMs: 50);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      container.read(listeningHistoryProvider)['/a.mp3'],
      const ListenEntry(count: 2, lastPlayedMs: 50),
    );
  });

  test('a rename by the app carries the listens over', () async {
    final dir = await Directory.systemTemp.createTemp('musync_history_');
    addTearDown(() => dir.delete(recursive: true));
    final store = ListeningHistoryStore(root: dir);
    await store.save({
      '/old.mp3': const ListenEntry(count: 3, lastPlayedMs: 30),
      '/new.mp3': const ListenEntry(count: 1, lastPlayedMs: 10),
    });
    final container = ProviderContainer(
      overrides: [listeningHistoryStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    await container
        .read(listeningHistoryProvider.notifier)
        .movePath('/old.mp3', '/new.mp3');

    final expected = {'/new.mp3': const ListenEntry(count: 4, lastPlayedMs: 30)};
    expect(container.read(listeningHistoryProvider), expected);
    expect(await store.load(), expected);
  });

  test('a reload (import) reads the file again, never overwrites it', () async {
    final dir = await Directory.systemTemp.createTemp('musync_history_');
    addTearDown(() => dir.delete(recursive: true));
    final store = ListeningHistoryStore(root: dir);
    await store.save({'/old.mp3': const ListenEntry(count: 1, lastPlayedMs: 1)});
    final container = ProviderContainer(
      overrides: [listeningHistoryStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    container.read(listeningHistoryProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // An import writes the file, then invalidates the provider.
    await store.save({
      '/imported.mp3': const ListenEntry(count: 4, lastPlayedMs: 7),
    });
    container.invalidate(listeningHistoryProvider);
    container.read(listeningHistoryProvider);
    // A listen landing before the reload is kept, on top of the import.
    await container
        .read(listeningHistoryProvider.notifier)
        .record('/new.mp3', atMs: 9);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(listeningHistoryProvider), {
      '/imported.mp3': const ListenEntry(count: 4, lastPlayedMs: 7),
      '/new.mp3': const ListenEntry(count: 1, lastPlayedMs: 9),
    });
    expect(
      (await store.load()).keys,
      unorderedEquals(['/imported.mp3', '/new.mp3']),
    );
  });
}
