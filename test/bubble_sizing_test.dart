// The bubble keeps one steady width, whatever the line.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/bubble/data/bubble_payload.dart';
import 'package:musync/features/bubble/data/bubble_sizing.dart';

void main() {
  test('leaves the screen margins on both sides', () {
    expect(bubbleFixedWidth(400), 400 - 2 * kBubbleScreenMargin);
  });

  test('never wider than the screen', () {
    expect(bubbleFixedWidth(360), lessThanOrEqualTo(360));
  });

  test('a wider screen gives a wider bubble', () {
    expect(bubbleFixedWidth(480), greaterThan(bubbleFixedWidth(320)));
  });

  test('stays usable on an absurdly small screen', () {
    expect(bubbleFixedWidth(100), kBubbleMinWidth);
  });

  test('a short line needs the default two visual lines', () {
    expect(bubbleActiveLinesFor('Hello', 360), 2);
  });

  test('a very long line needs more visual lines, capped at five', () {
    final long = List.filled(40, 'mot').join(' ');
    final lines = bubbleActiveLinesFor(long, 360);
    expect(lines, greaterThan(2));
    expect(lines, lessThanOrEqualTo(5));
  });

  test('an absurdly long line is capped at five visual lines', () {
    final absurd = List.filled(400, 'mot').join(' ');
    expect(bubbleActiveLinesFor(absurd, 360), 5);
  });

  test('two visual lines keep the current default height', () {
    expect(bubbleHeightForActiveLines(2, 2), bubbleHeightFor(2));
  });

  test('extra visual lines grow the bubble, the setting stays the base', () {
    expect(bubbleHeightForActiveLines(1, 2), bubbleHeightFor(1));
    expect(bubbleHeightForActiveLines(3, 2), bubbleHeightFor(3));
    expect(
      bubbleHeightForActiveLines(2, 4),
      greaterThan(bubbleHeightForActiveLines(2, 2)),
    );
  });
}
