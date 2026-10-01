/// How wide the floating bubble is.
///
/// One steady width, whatever the line: the bubble is a full-width pill near
/// the top of the screen, the lyric centered inside it. (An earlier version
/// sized the window to each line; short lines made it shrink and twitch
/// between widths.)
library;

import 'package:flutter/painting.dart';

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
