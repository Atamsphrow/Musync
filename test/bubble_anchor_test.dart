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
}
