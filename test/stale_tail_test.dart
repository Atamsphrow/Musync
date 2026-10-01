import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/bubble/providers/bubble_provider.dart';

void main() {
  group('isStaleTailSample', () {
    test('no previous tail: never stale', () {
      expect(isStaleTailSample(null, 239500), isFalse);
      expect(isStaleTailSample(null, 0), isFalse);
    });

    test('sample at the old duration is the stale tail', () {
      // Previous track was 240 s; the platform still reports its clamped
      // tail after the automatic track change.
      expect(isStaleTailSample(240000, 240000), isTrue);
      expect(isStaleTailSample(240000, 239500), isTrue);
      // Inside the clamp zone, boundaries inclusive.
      expect(isStaleTailSample(240000, 237000), isTrue);
      expect(isStaleTailSample(240000, 242000), isTrue);
    });

    test('sample outside the clamp zone: new track confirmed', () {
      expect(isStaleTailSample(240000, 236999), isFalse);
      expect(isStaleTailSample(240000, 242001), isFalse);
      expect(isStaleTailSample(240000, 500), isFalse);
      expect(isStaleTailSample(240000, 0), isFalse);
    });

    test('guard expires after its time window: user seek trusted', () {
      // Track changed 5 s ago; the user seeked the new track into the old
      // track's tail zone. The guard must not swallow this legit sample.
      expect(
        isStaleTailSample(180000, 179000, armedAtMs: 1000, nowMs: 6000),
        isFalse,
      );
      // Same sample, but right after the change: still the stale tail.
      expect(
        isStaleTailSample(180000, 179000, armedAtMs: 1000, nowMs: 1500),
        isTrue,
      );
      // Without timestamps (legacy callers): zone logic unchanged.
      expect(isStaleTailSample(180000, 179000), isTrue);
    });

    test('short previous track: the guard never arms', () {
      // A 3 s tail would swallow the new track's early positions, so the
      // guard stays off: a skipped track cannot produce a stale tail.
      expect(isStaleTailSample(3000, 3000), isFalse);
      expect(isStaleTailSample(3000, 200), isFalse);
      expect(isStaleTailSample(10000, 10000), isFalse);
      expect(isStaleTailSample(10001, 10001), isTrue);
    });
  });
}
