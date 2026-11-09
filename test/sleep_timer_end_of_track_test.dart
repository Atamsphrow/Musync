// G72: `playerStateStream` is just_audio's BehaviorSubject — subscribing
// replays the current value at once. If the player already sits on
// `completed` when the end-of-track timer is armed, that replay must not
// end the timer on the spot: only a `completed` arriving after the
// subscription is a track actually ending under this timer.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/providers/sleep_timer_provider.dart';

class _FakePlayer extends AudioPlayerService {
  // Single-subscription controllers: an event added before `listen` is
  // buffered and delivered on subscribe — the same replay a
  // BehaviorSubject gives the timer in production.
  final playerStateController = StreamController<PlayerState>();
  final positionController = StreamController<Duration>();
  // Broadcast: never listened to in this test, and `close()` on a
  // single-subscription controller with no listener never completes.
  final durationController = StreamController<Duration?>.broadcast();

  int pauseCalls = 0;

  @override
  Stream<PlayerState> get playerStateStream => playerStateController.stream;

  @override
  Stream<Duration> get positionStream => positionController.stream;

  @override
  Stream<Duration?> get durationStream => durationController.stream;

  @override
  Future<void> pause() async {
    pauseCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a completed replayed at subscription does not end the timer', () async {
    final player = _FakePlayer();
    addTearDown(() async {
      await player.playerStateController.close();
      await player.positionController.close();
      await player.durationController.close();
    });
    // Already `completed` before the timer subscribes: the replay.
    player.playerStateController.add(
      PlayerState(false, ProcessingState.completed),
    );

    final container = ProviderContainer(
      overrides: [audioPlayerServiceProvider.overrideWithValue(player)],
    );
    addTearDown(container.dispose);

    container
        .read(sleepTimerProvider.notifier)
        .setOption(SleepTimerOption.endOfTrack);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(sleepTimerProvider).active, isTrue);
    expect(
      container.read(sleepTimerProvider).option,
      SleepTimerOption.endOfTrack,
    );
    expect(player.pauseCalls, 0);

    // A real end arriving after the subscription still ends the timer.
    player.playerStateController.add(
      PlayerState(false, ProcessingState.completed),
    );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(sleepTimerProvider).active, isFalse);
    expect(player.pauseCalls, 1);
  });
}
