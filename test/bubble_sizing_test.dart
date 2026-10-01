// The bubble keeps one steady width, whatever the line.
import 'package:flutter_test/flutter_test.dart';
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
}
