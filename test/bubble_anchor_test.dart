import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/bubble/data/bubble_payload.dart';
import 'package:musync/features/bubble/ui/lyrics_bubble.dart';

BubblePayload _payload({int? activeIndex, int? positionMs, int? sampledAtMs}) {
  final timed = [
    {'ms': 0, 't': 'one'},
    {'ms': 5000, 't': 'two'},
    {'ms': 10000, 't': 'three'},
  ];
  return BubblePayload(
    previous: '',
    current: 'two',
    next: 'three',
    lines: 2,
    widthDp: 300,
    songId: '1',
    timedLines: timed,
    activeIndex: activeIndex,
    positionMs: positionMs,
    sampledAtMs: sampledAtMs,
  );
}

List<TimedLineJson> get _timed => [
  {'ms': 0, 't': 'one'},
  {'ms': 5000, 't': 'two'},
  {'ms': 10000, 't': 'three'},
];

void main() {
  group('bubbleAnchorFor', () {
    test('a stale position never throws the ticker before the active line',
        () {
      // The flicker: payload draws line 1 (at 5000 ms) but carries a
      // position sample from 3000 ms. The anchor must be raised to the
      // line, not left at the stale sample.
      final anchor = bubbleAnchorFor(
        _payload(activeIndex: 1, positionMs: 3000, sampledAtMs: 2900),
        _timed,
        now: DateTime.fromMillisecondsSinceEpoch(3100),
      );
      expect(anchor.anchorMs, 5000);
      expect(
        anchor.anchorTime,
        DateTime.fromMillisecondsSinceEpoch(3100),
      );
    });

    test('a fresh position is kept as-is', () {
      final anchor = bubbleAnchorFor(
        _payload(activeIndex: 1, positionMs: 7000, sampledAtMs: 6900),
        _timed,
      );
      expect(anchor.anchorMs, 7000);
      expect(
        anchor.anchorTime,
        DateTime.fromMillisecondsSinceEpoch(6900),
      );
    });

    test('without a position it falls back to the active line timestamp',
        () {
      final anchor = bubbleAnchorFor(
        _payload(activeIndex: 2),
        _timed,
        now: DateTime.fromMillisecondsSinceEpoch(12345),
      );
      expect(anchor.anchorMs, 10000);
      expect(
        anchor.anchorTime,
        DateTime.fromMillisecondsSinceEpoch(12345),
      );
    });

    test('without a position or a line it anchors at zero', () {
      final anchor = bubbleAnchorFor(_payload(), _timed);
      expect(anchor.anchorMs, 0);
    });
  });

  group('bubbleNextChangeAfter', () {
    test('before the first line it returns the first timestamp', () {
      expect(bubbleNextChangeAfter(_timed, -100), 0);
    });

    test('between lines it returns the next timestamp', () {
      expect(bubbleNextChangeAfter(_timed, 0), 5000);
      expect(bubbleNextChangeAfter(_timed, 4999), 5000);
      expect(bubbleNextChangeAfter(_timed, 5000), 10000);
    });

    test('past the last line it returns null', () {
      expect(bubbleNextChangeAfter(_timed, 10000), isNull);
      expect(bubbleNextChangeAfter(_timed, 999999), isNull);
    });

    test('empty timed lines return null', () {
      expect(bubbleNextChangeAfter(const [], 0), isNull);
    });

    test('duplicate timestamps are skipped as one change', () {
      final dup = [
        {'ms': 0, 't': 'a'},
        {'ms': 5000, 't': 'b'},
        {'ms': 5000, 't': 'c'},
        {'ms': 9000, 't': 'd'},
      ];
      expect(bubbleNextChangeAfter(dup, 4999), 5000);
      expect(bubbleNextChangeAfter(dup, 5000), 9000);
    });
  });
}
