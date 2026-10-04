import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musync/features/player/providers/player_provider.dart';

/// The sleep timer options offered in the now-playing screen's sheet.
enum SleepTimerOption {
  disabled,
  min15,
  min30,
  min45,
  min60,
  min90,
  endOfTrack;

  /// Null for [disabled] and [endOfTrack]: neither is a wall-clock duration.
  Duration? get duration => switch (this) {
        SleepTimerOption.min15 => const Duration(minutes: 15),
        SleepTimerOption.min30 => const Duration(minutes: 30),
        SleepTimerOption.min45 => const Duration(minutes: 45),
        SleepTimerOption.min60 => const Duration(minutes: 60),
        SleepTimerOption.min90 => const Duration(minutes: 90),
        SleepTimerOption.disabled || SleepTimerOption.endOfTrack => null,
      };

  String get label => switch (this) {
        SleepTimerOption.disabled => 'Désactivé',
        SleepTimerOption.min15 => '15 min',
        SleepTimerOption.min30 => '30 min',
        SleepTimerOption.min45 => '45 min',
        SleepTimerOption.min60 => '60 min',
        SleepTimerOption.min90 => '90 min',
        SleepTimerOption.endOfTrack => 'Fin du morceau',
      };
}

class SleepTimerState {
  final SleepTimerOption option;

  /// Wall-clock time left, rounded up to the minute. Null when the timer is
  /// disabled or waits for the end of the track.
  final Duration? remaining;

  const SleepTimerState({
    this.option = SleepTimerOption.disabled,
    this.remaining,
  });

  bool get active => option != SleepTimerOption.disabled;
}

final sleepTimerProvider =
    NotifierProvider<SleepTimerController, SleepTimerState>(
  SleepTimerController.new,
);

/// Owns the sleep timer's [Timer] so it survives widget rebuilds.
///
/// Setting an option replaces the previous timer; [SleepTimerOption.disabled]
/// cancels it. The timer is wall-clock based and fires even while paused —
/// pausing the player does not postpone bedtime. Expiry pauses playback
/// through [AudioPlayerService.pause].
class SleepTimerController extends Notifier<SleepTimerState> {
  Timer? _timer;
  Timer? _ticker;
  StreamSubscription<PlayerState>? _completionSub;

  @override
  SleepTimerState build() {
    ref.onDispose(_cancelAll);
    return const SleepTimerState();
  }

  /// Replaces the current timer with [option], or cancels it for
  /// [SleepTimerOption.disabled].
  void setOption(SleepTimerOption option) {
    _cancelAll();
    if (option == SleepTimerOption.disabled) {
      state = const SleepTimerState();
      return;
    }
    final duration = option.duration;
    if (duration != null) {
      final deadline = DateTime.now().add(duration);
      _timer = Timer(duration, _onExpired);
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) return; // [_onExpired] owns the landing.
        // Rounded up to the minute, and only published when the minute
        // changes so listeners don't rebuild every second.
        final snapped = Duration(
          minutes: left.inMinutes + (left.inSeconds % 60 > 0 ? 1 : 0),
        );
        if (snapped != state.remaining) {
          state = SleepTimerState(option: option, remaining: snapped);
        }
      });
      state = SleepTimerState(option: option, remaining: duration);
    } else {
      // End of track: just_audio emits `ProcessingState.completed` when the
      // current source finishes, before moving on (or looping).
      final service = ref.read(audioPlayerServiceProvider);
      _completionSub = service.playerStateStream.listen((playerState) {
        if (playerState.processingState == ProcessingState.completed) {
          _onTrackEnded();
        }
      });
      state = const SleepTimerState(option: SleepTimerOption.endOfTrack);
    }
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
    _timer = null;
    _ticker = null;
    _completionSub = null;
  }
}
