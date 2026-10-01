/// How wide the floating bubble is.
///
/// One steady width, whatever the line: the bubble is a full-width pill near
/// the top of the screen, the lyric centered inside it. (An earlier version
/// sized the window to each line; short lines made it shrink and twitch
/// between widths.)
library;

import 'package:flutter/painting.dart';
import 'package:musync/features/bubble/data/bubble_payload.dart';

/// Breathing room kept between the bubble and each edge of the screen, in dp.
const double kBubbleScreenMargin = 16;

/// Narrowest the bubble gets, in dp. Only matters on absurdly small screens.
const int kBubbleMinWidth = 200;

/// The bubble's width in dp on a screen [screenWidthDp] wide.
int bubbleFixedWidth(double screenWidthDp) =>
    (screenWidthDp - 2 * kBubbleScreenMargin)
        .floor()
        .clamp(kBubbleMinWidth, 100000);

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

/// Horizontal space the active line does not get: the bubble's outer margin,
/// its padding, and the close button. In dp.
const double _kBubbleTextChrome = 64;

/// How many visual lines the active lyric needs at the bubble's fixed width.
///
/// Two is the default look (the height the bubble opens with); a very long
/// line grows the bubble instead of being squeezed, up to five lines. The
/// width never moves — only the height adapts.
int bubbleActiveLinesFor(
  String text,
  double widthDp, {
  double textScaleFactor = 1.0,
}) {
  final scaler = TextScaler.linear(textScaleFactor);
  final lineHeight =
      kBubbleActiveStyle.fontSize! * (kBubbleActiveStyle.height ?? 1.0);
  final painter = TextPainter(
    text: TextSpan(text: text, style: kBubbleActiveStyle),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 99,
  )..layout(maxWidth: widthDp - _kBubbleTextChrome);
  return (painter.height / (lineHeight * textScaleFactor)).ceil().clamp(2, 5);
}

/// Extra height, in dp, for an active line that needs more than the default
/// two visual lines. One more line of the active style, rounded.
const int _kBubbleExtraLineHeight = 22;

/// The bubble's height in dp for a payload showing [lines] (the 1/2/3 setting)
/// whose active line needs [activeLines] visual lines. Two visual lines keep
/// the current default height; longer lines grow it.
int bubbleHeightForActiveLines(
  int lines,
  int activeLines, {
  double textScaleFactor = 1.0,
}) =>
    bubbleHeightFor(lines) +
    ((activeLines.clamp(2, 5) - 2) * _kBubbleExtraLineHeight * textScaleFactor)
        .round();
