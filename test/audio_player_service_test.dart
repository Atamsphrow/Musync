import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/player/data/audio_player_service.dart';

void main() {
  group('AudioPlayerService.clampSeekBy', () {
    test('leaves a mid-track seek untouched', () {
      expect(
        AudioPlayerService.clampSeekBy(
          position: const Duration(seconds: 30),
          delta: const Duration(seconds: 5),
          duration: const Duration(seconds: 60),
        ),
        const Duration(seconds: 35),
      );
    });

    test('lands below the duration when the target reaches it exactly', () {
      expect(
        AudioPlayerService.clampSeekBy(
          position: const Duration(seconds: 55),
          delta: const Duration(seconds: 5),
          duration: const Duration(seconds: 60),
        ),
        const Duration(seconds: 59, milliseconds: 750),
      );
    });

    test('lands below the duration when the target overshoots it', () {
      expect(
        AudioPlayerService.clampSeekBy(
          position: const Duration(seconds: 58),
          delta: const Duration(seconds: 5),
          duration: const Duration(seconds: 60),
        ),
        const Duration(seconds: 59, milliseconds: 750),
      );
    });

    test('never seeks to exactly the duration', () {
      final result = AudioPlayerService.clampSeekBy(
        position: const Duration(seconds: 59, milliseconds: 900),
        delta: const Duration(seconds: 5),
        duration: const Duration(seconds: 60),
      );
      expect(result < const Duration(seconds: 60), isTrue);
    });

    test('clamps a backward seek below zero to zero', () {
      expect(
        AudioPlayerService.clampSeekBy(
          position: const Duration(seconds: 3),
          delta: const Duration(seconds: -5),
          duration: const Duration(seconds: 60),
        ),
        Duration.zero,
      );
    });

    test('passes the target through when the duration is unknown', () {
      expect(
        AudioPlayerService.clampSeekBy(
          position: const Duration(seconds: 58),
          delta: const Duration(seconds: 5),
          duration: null,
        ),
        const Duration(seconds: 63),
      );
    });

    test('falls back to zero on a track shorter than the margin', () {
      expect(
        AudioPlayerService.clampSeekBy(
          position: Duration.zero,
          delta: const Duration(seconds: 5),
          duration: const Duration(milliseconds: 100),
        ),
        Duration.zero,
      );
    });
  });

  group('AudioPlayerService.shouldCorrectLoopAnchor', () {
    final now = DateTime(2026, 10, 30, 1, 0, 0);
    const duration = Duration(minutes: 3);

    bool check({
      Duration prev = const Duration(minutes: 2, seconds: 59),
      Duration event = const Duration(minutes: 1),
      int? prevIndex = 0,
      int? eventIndex = 0,
      bool loop = true,
      Duration? dur = duration,
      bool playing = true,
      DateTime? lastSeek,
    }) =>
        AudioPlayerService.shouldCorrectLoopAnchor(
          prevExtrapolated: prev,
          eventUpdatePosition: event,
          prevIndex: prevIndex,
          eventIndex: eventIndex,
          loopEnabled: loop,
          duration: dur,
          playing: playing,
          lastServiceSeekAt: lastSeek,
          now: now,
        );

    test('fires on a loop with a stale anchor far from the end', () {
      expect(check(), isTrue);
    });

    test('fires on a loop with a stale anchor parked near the end', () {
      // Jump of only one second, but still a backward jump near the end:
      // the stale target was the user pausing at 2:59.
      expect(
        check(event: const Duration(minutes: 2, seconds: 58)),
        isTrue,
      );
    });

    test('ignores a steady event near the end', () {
      // Pause/resume or buffering: same position, no backward jump.
      expect(
        check(event: const Duration(minutes: 2, seconds: 59)),
        isFalse,
      );
    });

    test('ignores its own seek echo', () {
      expect(
        check(lastSeek: now.subtract(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('ignores a track change', () {
      expect(check(eventIndex: 1), isFalse);
    });

    test('ignores a mid-track backward jump', () {
      // A backward seek mid-song is not a loop: previous position far
      // from the end.
      expect(
        check(prev: const Duration(minutes: 1)),
        isFalse,
      );
    });

    test('ignores everything when not looping', () {
      expect(check(loop: false), isFalse);
    });

    test('ignores everything when paused', () {
      expect(check(playing: false), isFalse);
    });

    test('ignores everything without a duration', () {
      expect(check(dur: null), isFalse);
    });
  });
}
