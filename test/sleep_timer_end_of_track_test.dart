// G72: `playerStateStream` is just_audio's BehaviorSubject — subscribing
// replays the current value at once. If the player already sits on
// `completed` when the end-of-track timer is armed, that replay must not
// end the timer on the spot: only a `completed` arriving after the
// subscription is a track actually ending under this timer.
//
// G71 (suite) : la fin de morceau est signalée par la discontinuité
// `autoAdvance`, pas par le seuil de position — sauf en file d'un seul
// morceau en boucle (`LoopMode.all`), seul cas sans signal exact.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/providers/sleep_timer_provider.dart';

const _songA = Song(
  id: 1,
  title: 'A',
  artist: 'A',
  album: 'A',
  duration: 10000,
  filePath: '/a.mp3',
);
const _songB = Song(
  id: 2,
  title: 'B',
  artist: 'B',
  album: 'B',
  duration: 10000,
  filePath: '/b.mp3',
);

class _FakePlayer extends AudioPlayerService {
  // Single-subscription controllers: an event added before `listen` is
  // buffered and delivered on subscribe — the same replay a
  // BehaviorSubject gives the timer in production.
  final playerStateController = StreamController<PlayerState>();
  final positionController = StreamController<Duration>();
  final positionDiscontinuityController =
      StreamController<PositionDiscontinuity>();
  // Broadcast: never listened to in this test, and `close()` on a
  // single-subscription controller with no listener never completes.
  final durationController = StreamController<Duration?>.broadcast();

  LoopMode loopModeOverride = LoopMode.off;
  List<Song> queueOverride = [_songA, _songB];

  int pauseCalls = 0;

  @override
  Stream<PlayerState> get playerStateStream => playerStateController.stream;

  @override
  Stream<Duration> get positionStream => positionController.stream;

  @override
  Stream<PositionDiscontinuity> get positionDiscontinuityStream =>
      positionDiscontinuityController.stream;

  @override
  Stream<Duration?> get durationStream => durationController.stream;

  @override
  LoopMode get loopMode => loopModeOverride;

  @override
  List<Song> get queue => queueOverride;

  @override
  Future<void> pause() async {
    pauseCalls++;
  }
}

/// Établit la durée courante pour le minuteur.
///
/// `durationProvider` ne s'abonne à `durationStream` qu'à sa première
/// lecture (dans l'écouteur de position), et le flux est broadcast : un
/// événement émis avant n'est pas rejoué. On amorce avec une position
/// (qui déclenche l'abonnement), puis on (ré)émet la durée.
Future<void> _setDuration(_FakePlayer player, Duration d) async {
  player.positionController.add(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  player.durationController.add(d);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a completed replayed at subscription does not end the timer', () async {
    final player = _FakePlayer();
    addTearDown(() async {
      await player.playerStateController.close();
      await player.positionController.close();
      await player.positionDiscontinuityController.close();
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

  // G71 : la coupure tombe à la vraie fin de piste (discontinuité
  // autoAdvance), pas ~0,2 s avant (seuil de position).
  test('an autoAdvance discontinuity ends the timer, with no early cut',
      () async {
    final player = _FakePlayer();
    addTearDown(() async {
      await player.playerStateController.close();
      await player.positionController.close();
      await player.positionDiscontinuityController.close();
      await player.durationController.close();
    });
    final container = ProviderContainer(
      overrides: [audioPlayerServiceProvider.overrideWithValue(player)],
    );
    addTearDown(container.dispose);

    container
        .read(sleepTimerProvider.notifier)
        .setOption(SleepTimerOption.endOfTrack);
    await Future<void>.delayed(Duration.zero);
    await _setDuration(player, const Duration(seconds: 10));

    // 100 ms avant la fin : l'ancien seuil coupait ici. Plus maintenant.
    player.positionController.add(const Duration(milliseconds: 9900));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sleepTimerProvider).active, isTrue);
    expect(player.pauseCalls, 0);

    // La vraie fin : just_audio avance à la piste suivante.
    player.positionDiscontinuityController.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.autoAdvance,
        PlaybackEvent(),
        PlaybackEvent(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(sleepTimerProvider).active, isFalse);
    expect(player.pauseCalls, 1);
  });

  test('a seek discontinuity does not end the timer', () async {
    final player = _FakePlayer();
    addTearDown(() async {
      await player.playerStateController.close();
      await player.positionController.close();
      await player.positionDiscontinuityController.close();
      await player.durationController.close();
    });
    final container = ProviderContainer(
      overrides: [audioPlayerServiceProvider.overrideWithValue(player)],
    );
    addTearDown(container.dispose);

    container
        .read(sleepTimerProvider.notifier)
        .setOption(SleepTimerOption.endOfTrack);
    await Future<void>.delayed(Duration.zero);

    // Un saut manuel, même vers une autre piste : la piste en cours n'a
    // pas fini, le minuteur attend la fin de la nouvelle piste.
    player.positionDiscontinuityController.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.seek,
        PlaybackEvent(),
        PlaybackEvent(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(sleepTimerProvider).active, isTrue);
    expect(player.pauseCalls, 0);
  });

  test('single-track loop-all still uses the position threshold', () async {
    final player = _FakePlayer()
      ..loopModeOverride = LoopMode.all
      ..queueOverride = [_songA];
    addTearDown(() async {
      await player.playerStateController.close();
      await player.positionController.close();
      await player.positionDiscontinuityController.close();
      await player.durationController.close();
    });
    final container = ProviderContainer(
      overrides: [audioPlayerServiceProvider.overrideWithValue(player)],
    );
    addTearDown(container.dispose);

    container
        .read(sleepTimerProvider.notifier)
        .setOption(SleepTimerOption.endOfTrack);
    await Future<void>.delayed(Duration.zero);
    await _setDuration(player, const Duration(seconds: 10));

    // Un seul morceau en boucle : l'index ne change jamais, `completed`
    // ne se déclenche pas — le seuil de 200 ms est le seul signal.
    player.positionController.add(const Duration(milliseconds: 9900));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(sleepTimerProvider).active, isFalse);
    expect(player.pauseCalls, 1);
  });

  test('a loop-one wrap ends the timer through autoAdvance', () async {
    final player = _FakePlayer()..loopModeOverride = LoopMode.one;
    addTearDown(() async {
      await player.playerStateController.close();
      await player.positionController.close();
      await player.positionDiscontinuityController.close();
      await player.durationController.close();
    });
    final container = ProviderContainer(
      overrides: [audioPlayerServiceProvider.overrideWithValue(player)],
    );
    addTearDown(container.dispose);

    container
        .read(sleepTimerProvider.notifier)
        .setOption(SleepTimerOption.endOfTrack);
    await Future<void>.delayed(Duration.zero);
    await _setDuration(player, const Duration(seconds: 10));

    // En boucle sur un morceau, le seuil ne s'applique pas : le rebouclage
    // est détecté par just_audio (autoAdvance), pas par la position.
    player.positionController.add(const Duration(milliseconds: 9900));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sleepTimerProvider).active, isTrue);
    expect(player.pauseCalls, 0);

    player.positionDiscontinuityController.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.autoAdvance,
        PlaybackEvent(),
        PlaybackEvent(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(sleepTimerProvider).active, isFalse);
    expect(player.pauseCalls, 1);
  });
}
