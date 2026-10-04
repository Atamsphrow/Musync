// The sleep timer's options and state: durations, French labels, and the
// active flag the now-playing button reads. Pure logic only — the timing
// itself lives in [SleepTimerController] and needs a real player.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/player/providers/sleep_timer_provider.dart';

void main() {
  group('SleepTimerOption', () {
    test('fixed options carry their wall-clock duration', () {
      expect(SleepTimerOption.min15.duration, const Duration(minutes: 15));
      expect(SleepTimerOption.min30.duration, const Duration(minutes: 30));
      expect(SleepTimerOption.min45.duration, const Duration(minutes: 45));
      expect(SleepTimerOption.min60.duration, const Duration(minutes: 60));
      expect(SleepTimerOption.min90.duration, const Duration(minutes: 90));
    });

    test('disabled, custom and end-of-track are not wall-clock durations', () {
      expect(SleepTimerOption.disabled.duration, isNull);
      expect(SleepTimerOption.custom.duration, isNull);
      expect(SleepTimerOption.endOfTrack.duration, isNull);
    });

    test('labels are French', () {
      expect(SleepTimerOption.disabled.label, 'Désactivé');
      expect(SleepTimerOption.min15.label, '15 min');
      expect(SleepTimerOption.min30.label, '30 min');
      expect(SleepTimerOption.min45.label, '45 min');
      expect(SleepTimerOption.min60.label, '60 min');
      expect(SleepTimerOption.min90.label, '90 min');
      expect(SleepTimerOption.custom.label, 'Personnalisé');
      expect(SleepTimerOption.endOfTrack.label, 'Fin du morceau');
    });
  });

  group('SleepTimerState', () {
    test('starts disabled and inactive', () {
      const state = SleepTimerState();
      expect(state.option, SleepTimerOption.disabled);
      expect(state.remaining, isNull);
      expect(state.active, isFalse);
    });

    test('any option but disabled is active', () {
      for (final option in SleepTimerOption.values) {
        final state = SleepTimerState(option: option);
        expect(
          state.active,
          option != SleepTimerOption.disabled,
          reason: option.name,
        );
      }
    });

    test('custom display label shows the chosen minutes', () {
      const state = SleepTimerState(
        option: SleepTimerOption.custom,
        customMinutes: 20,
      );
      expect(state.displayLabel, 'Personnalisé · 20 min');
      expect(state.active, isTrue);
    });

    test('display label falls back to the plain label', () {
      expect(
        const SleepTimerState().displayLabel,
        'Désactivé',
      );
      expect(
        const SleepTimerState(option: SleepTimerOption.min30).displayLabel,
        '30 min',
      );
    });
  });
}
