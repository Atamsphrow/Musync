import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';

/// The sleep timer options offered in the now-playing screen's sheet.
enum SleepTimerOption {
  disabled,
  min15,
  min30,
  min45,
  min60,
  min90,
  custom,
  endOfTrack;

  /// Null for [disabled], [custom] and [endOfTrack]: the custom duration is
  /// carried in [SleepTimerState.customMinutes] instead.
  Duration? get duration => switch (this) {
        SleepTimerOption.min15 => const Duration(minutes: 15),
        SleepTimerOption.min30 => const Duration(minutes: 30),
        SleepTimerOption.min45 => const Duration(minutes: 45),
        SleepTimerOption.min60 => const Duration(minutes: 60),
        SleepTimerOption.min90 => const Duration(minutes: 90),
        SleepTimerOption.disabled ||
        SleepTimerOption.custom ||
        SleepTimerOption.endOfTrack =>
          null,
      };

  String get label => switch (this) {
        SleepTimerOption.disabled => 'Désactivé',
        SleepTimerOption.min15 => '15 min',
        SleepTimerOption.min30 => '30 min',
        SleepTimerOption.min45 => '45 min',
        SleepTimerOption.min60 => '60 min',
        SleepTimerOption.min90 => '90 min',
        SleepTimerOption.custom => 'Personnalisé',
        SleepTimerOption.endOfTrack => 'Fin du morceau',
      };
}

class SleepTimerState {
  final SleepTimerOption option;

  /// Time left, rounded up to the minute. Null when the timer is
  /// disabled or waits for the end of the track.
  final Duration? remaining;

  /// The chosen minutes when [option] is [SleepTimerOption.custom].
  final int? customMinutes;

  const SleepTimerState({
    this.option = SleepTimerOption.disabled,
    this.remaining,
    this.customMinutes,
  });

  bool get active => option != SleepTimerOption.disabled;

  /// What the sheet and tooltips show for the current option.
  String get displayLabel =>
      option == SleepTimerOption.custom && customMinutes != null
          ? 'Personnalisé · $customMinutes min'
          : option.label;
}

final sleepTimerProvider =
    NotifierProvider<SleepTimerController, SleepTimerState>(
  SleepTimerController.new,
);

/// Owns the sleep timer's [Timer] so it survives widget rebuilds.
///
/// Setting an option replaces the previous timer; [SleepTimerOption.disabled]
/// cancels it. The timer is monotone (a `Stopwatch` + `Timer`) and fires
/// even while paused — pausing the player does not postpone bedtime. Expiry
/// pauses playback through [AudioPlayerService.pause].
class SleepTimerController extends Notifier<SleepTimerState> {
  Timer? _timer;
  Timer? _ticker;
  StreamSubscription<PlayerState>? _completionSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PositionDiscontinuity>? _discontinuitySub;

  @override
  SleepTimerState build() {
    ref.onDispose(_cancelAll);
    return const SleepTimerState();
  }

  /// Replaces the current timer with [option], or cancels it for
  /// [SleepTimerOption.disabled]. [SleepTimerOption.custom] needs a duration:
  /// use [setCustomMinutes] for it instead.
  void setOption(SleepTimerOption option) {
    if (option == SleepTimerOption.custom) return;
    _cancelAll();
    if (option == SleepTimerOption.disabled) {
      state = const SleepTimerState();
      return;
    }
    final duration = option.duration;
    if (duration != null) {
      _startDurationTimer(option, duration);
    } else {
      // End of track.
      //
      // G71 : le seuil « fin du morceau » (500 ms, puis 200 ms en K85)
      // coupait jusqu'à ~0,2 s avant la fin réelle, parce que la position
      // n'est connue qu'à ~200 ms près (un tick peut tomber juste dans la
      // fenêtre). Le signal exact existe : just_audio émet une
      // `PositionDiscontinuity` de raison `autoAdvance` quand la piste
      // avance d'elle-même — changement d'index sans seek, ou rebouclage
      // en `LoopMode.one` — et jamais sur un saut manuel. La coupure tombe
      // donc à la vraie fin de piste.
      //
      // Pourquoi pas `ProcessingState.completed` seul : la file est un seul
      // `ConcatenatingAudioSource`, just_audio ne signale `completed` qu'à
      // la fin de la DERNIÈRE piste (et jamais en `LoopMode.one`). Il reste
      // en backstop pour cette dernière piste.
      //
      // Reste un cas sans signal exact : une file d'un seul morceau en
      // boucle (`LoopMode.all`) — l'index ne change jamais (le rebouclage
      // sur le même index n'émet pas `autoAdvance`, qui exige
      // `LoopMode.one`), et `completed` ne se déclenche pas. Le seuil de
      // 200 ms survit là, et là seulement.
      final service = ref.read(audioPlayerServiceProvider);
      _discontinuitySub = service.positionDiscontinuityStream.listen((
        discontinuity,
      ) {
        if (discontinuity.reason == PositionDiscontinuityReason.autoAdvance) {
          _onTrackEnded();
        }
      });
      _positionSub = service.positionStream.listen((position) {
        if (!_needsPositionFallback(service)) return;
        final duration = ref.read(durationProvider).valueOrNull;
        if (duration == null || duration <= Duration.zero) return;
        if (position > Duration.zero &&
            duration - position <= const Duration(milliseconds: 200)) {
          _onTrackEnded();
        }
      });
      // G72: `playerStateStream` is just_audio's BehaviorSubject: subscribing
      // replays its current value at once. If the player already sits on
      // `completed` (last track ended before the timer was set), that replay
      // is not a track ending under this timer — it would cancel the timer
      // the instant it is armed. Only a `completed` that arrives after the
      // subscription counts. The service getter itself is left alone:
      // `playerStateProvider` needs the current value at subscription.
      _completionSub = service.playerStateStream.skip(1).listen((
        playerState,
      ) {
        if (playerState.processingState == ProcessingState.completed) {
          _onTrackEnded();
        }
      });
      state = const SleepTimerState(option: SleepTimerOption.endOfTrack);
    }
  }

  /// Starts a wall-clock timer for an arbitrary [minutes] count.
  ///
  /// A runtime check, not an assert: asserts are stripped in release, and
  /// `setCustomMinutes(0)` used to start an immediate `Timer(Duration.zero)`
  /// that paused playback at once, silently.
  void setCustomMinutes(int minutes) {
    if (minutes <= 0 || minutes > 1440) return;
    _cancelAll();
    _startDurationTimer(
      SleepTimerOption.custom,
      Duration(minutes: minutes),
      customMinutes: minutes,
    );
  }

  void _startDurationTimer(
    SleepTimerOption option,
    Duration duration, {
    int? customMinutes,
  }) {
    // Monotone, not wall-clock: `DateTime.now()` moves with a manual clock
    // change, an NTP correction or a time-zone hop, which used to
    // desynchronise the displayed countdown from the `Timer` that actually
    // fires (itself monotone). A `Stopwatch` measures the same elapsed time
    // the `Timer` does.
    final elapsed = Stopwatch()..start();
    _timer = Timer(duration, _onExpired);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = duration - elapsed.elapsed;
      if (left <= Duration.zero) return; // [_onExpired] owns the landing.
      // Rounded up to the minute, and only published when the minute
      // changes so listeners don't rebuild every second.
      final snapped = Duration(
        minutes: left.inMinutes + (left.inSeconds % 60 > 0 ? 1 : 0),
      );
      if (snapped != state.remaining) {
        state = SleepTimerState(
          option: option,
          remaining: snapped,
          customMinutes: customMinutes,
        );
      }
    });
    state = SleepTimerState(
      option: option,
      remaining: duration,
      customMinutes: customMinutes,
    );
  }

  void _onExpired() {
    _cancelAll();
    state = const SleepTimerState();
    unawaited(ref.read(audioPlayerServiceProvider).pause());
  }

  void _onTrackEnded() {
    _cancelAll();
    state = const SleepTimerState();
    unawaited(ref.read(audioPlayerServiceProvider).pause());
  }

  void _cancelAll() {
    _timer?.cancel();
    _ticker?.cancel();
    _completionSub?.cancel();
    _positionSub?.cancel();
    _discontinuitySub?.cancel();
    _timer = null;
    _ticker = null;
    _completionSub = null;
    _positionSub = null;
    _discontinuitySub = null;
  }

  /// Le seuil de position ne sert plus que de repli, pour le seul cas sans
  /// signal exact : une file d'un seul morceau en boucle (`LoopMode.all`) —
  /// l'index ne change jamais et `completed` ne se déclenche pas. Évalué à
  /// chaque tick : le mode de boucle comme la file peuvent changer pendant
  /// que le minuteur est armé.
  static bool _needsPositionFallback(AudioPlayerService service) =>
      service.loopMode == LoopMode.all && service.queue.length <= 1;
}
