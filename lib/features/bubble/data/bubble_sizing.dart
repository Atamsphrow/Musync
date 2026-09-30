/// How wide the floating bubble should be for what it is showing.
///
/// A short line in a full-width bubble is a lot of empty pill; a long one in a
/// narrow bubble wraps for no reason. So the width follows the widest line on
/// show, and never exceeds the screen.
///
/// Measured in the main isolate, with the same text styles the bubble draws in
/// (see `lyrics_bubble.dart` — keep the two in step), and sent to the overlay
/// as a resize.
library;

import 'package:flutter/painting.dart';
import 'package:musync/features/bubble/data/bubble_payload.dart';

/// Narrowest the bubble gets, in dp. Enough for the note and the close button.
const int kBubbleMinWidth = 120;

/// Breathing room kept between the bubble and each edge of the screen, in dp.
const double kBubbleScreenMargin = 12;

/// Widths move in steps this big. Without it, every line a few pixels longer
/// than the last one would resize the window, which is visible as a twitch.
const int kBubbleWidthStep = 24;

/// What the bubble draws around the text, in dp: its outer margin (4 + 4), its
/// left and right padding (16 + 8) and the close button (18 icon + 12 padding),
/// plus a little slack for font scaling.
const double _chrome = 8 + 24 + 30 + 10;

const TextStyle kBubbleActiveStyle = TextStyle(
  fontSize: 18,
  fontWeight: FontWeight.w700,
  height: 1.2,
);

const TextStyle kBubbleNeighbourStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w400,
  height: 1.2,
);

/// Width in dp for [payload] on a screen [screenWidthDp] wide.
int bubbleWidthFor(BubblePayload payload, double screenWidthDp) {
  final widest = [
    _measure(payload.current, kBubbleActiveStyle),
    if (payload.lines == 3) _measure(payload.previous, kBubbleNeighbourStyle),
    if (payload.lines >= 2) _measure(payload.next, kBubbleNeighbourStyle),
  ].reduce((a, b) => a > b ? a : b);

  final ceiling = (screenWidthDp - 2 * kBubbleScreenMargin).floor();
  final wanted = (widest + _chrome).ceil();

  final stepped = ((wanted / kBubbleWidthStep).ceil()) * kBubbleWidthStep;
  // A line too long for the screen simply wraps (the active one on two lines),
  // so the ceiling wins over the step.
  final upper = ceiling < kBubbleMinWidth ? kBubbleMinWidth : ceiling;
  return stepped.clamp(kBubbleMinWidth, upper).toInt();
}

/// Width of [text] on a single line, in dp.
double _measure(String text, TextStyle style) {
  if (text.isEmpty) return 0;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}
