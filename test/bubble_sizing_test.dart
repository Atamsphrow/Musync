// The bubble is as wide as what it shows, and never wider than the screen.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/bubble/data/bubble_payload.dart';
import 'package:musync/features/bubble/data/bubble_sizing.dart';

BubblePayload _showing(String current, {String next = '', int lines = 1}) =>
    BubblePayload(
      previous: '',
      current: current,
      next: next,
      lines: lines,
      widthDp: 200,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const phone = 400.0;

  test('a longer line makes a wider bubble', () {
    final short = bubbleWidthFor(_showing('Oui'), phone);
    final long = bubbleWidthFor(_showing('Une phrase un peu plus longue'), phone);
    expect(long, greaterThan(short));
  });

  test('never narrower than the minimum', () {
    expect(bubbleWidthFor(_showing(kBubbleIdle), phone),
        greaterThanOrEqualTo(kBubbleMinWidth));
  });

  test('never wider than the screen, whatever the line', () {
    final width = bubbleWidthFor(_showing('mot ' * 60), phone);
    expect(width, lessThanOrEqualTo(phone - 2 * kBubbleScreenMargin));
  });

  test('a narrower screen gives a narrower ceiling', () {
    final line = _showing('mot ' * 60);
    expect(bubbleWidthFor(line, 320), lessThan(bubbleWidthFor(line, 480)));
  });

  test('the next line counts only when it is shown', () {
    const next = 'Une ligne suivante vraiment longue';
    final hidden = bubbleWidthFor(_showing('Oui', next: next), phone);
    final shown = bubbleWidthFor(_showing('Oui', next: next, lines: 2), phone);
    expect(shown, greaterThan(hidden));
  });

  test('widths come in steps, so small changes do not resize the window', () {
    final w = bubbleWidthFor(_showing('Bonjour'), phone);
    expect(w % kBubbleWidthStep, 0);
  });

  test('a screen narrower than the minimum still gives a usable width', () {
    expect(bubbleWidthFor(_showing('Oui'), 100), kBubbleMinWidth);
  });
}
