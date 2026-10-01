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
}
