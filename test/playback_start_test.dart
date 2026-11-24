// Two things the player gets right now: a tool waits for playback to start,
// not to end; and a same-id update of the playing track (tag edit, rename)
// reaches the screens.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/tools/playback_tools.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';

class _StreamingPlayer extends AudioPlayerService {
  final songs = StreamController<Song?>.broadcast();

  @override
  Stream<Song?> get currentSongStream => songs.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a playback that never ends does not hold the caller', () async {
    final never = Completer<void>().future;
    final clock = Stopwatch()..start();
    await awaitPlaybackStart(
      never,
      window: const Duration(milliseconds: 50),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('a failure to start still reaches the caller', () async {
    await expectLater(
      awaitPlaybackStart(Future<void>.error(StateError('illisible'))),
      throwsStateError,
    );
  });

  test('the same track renamed or retagged is news to the screens', () async {
    final player = _StreamingPlayer();
    addTearDown(player.songs.close);
    final container = ProviderContainer(
      overrides: [audioPlayerServiceProvider.overrideWithValue(player)],
    );
    addTearDown(container.dispose);
    final seen = <Song?>[];
    container.listen(currentSongProvider, (_, next) => seen.add(next));
    await Future<void>.delayed(Duration.zero); // The stream is listened to.

    const song = Song(
      id: 7,
      title: 'Ancien',
      artist: 'A',
      album: 'B',
      duration: 1000,
      filePath: '/m/old.mp3',
    );
    player.songs.add(song);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(currentSongProvider)?.title, 'Ancien');
    player.songs.add(song.copyWith(title: 'Nouveau', filePath: '/m/new.mp3'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(currentSongProvider)?.filePath, '/m/new.mp3');

    // Both reached the listener: a plain Provider dropped the second one,
    // equal to the first by id.
    expect(seen.map((s) => s?.title), ['Ancien', 'Nouveau']);
  });
}
