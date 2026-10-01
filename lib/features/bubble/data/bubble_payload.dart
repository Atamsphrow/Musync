/// What the floating bubble shows, and how big the bubble is for it.
///
/// Plain Dart on purpose: the bubble runs in its own isolate, next to the main
/// one, and the only thing that crosses between them is the JSON of this class.
/// No Riverpod, no Flutter, so both sides can import it.
library;

import 'dart:convert';

/// Placeholder while nothing is being sung — before the first line, or when the
/// track has no synchronised lyrics.
const String kBubbleIdle = '♪';

/// Height of the bubble for 1, 2 or 3 lines, in dp.
int bubbleHeightFor(int lines) => switch (lines) {
  1 => 84,
  2 => 128,
  _ => 172,
};

class BubblePayload {
  final String previous;
  final String current;
  final String next;

  /// 1, 2 or 3: which of the three texts are drawn.
  final int lines;

  /// Width the overlay window should be, in dp. One steady full-width pill,
  /// whatever the line — the lyric is centered inside it. Computed in the
  /// main isolate and applied by the overlay isolate itself: `resizeOverlay`
  /// only reaches the plugin from the overlay side, a call from the main
  /// isolate throws `MissingPluginException` and silently leaves the bubble
  /// at its opening width.
  final int widthDp;

  const BubblePayload({
    required this.previous,
    required this.current,
    required this.next,
    required this.lines,
    required this.widthDp,
  });

  /// Nothing to sing: the bubble stays up, showing only the note.
  const BubblePayload.idle(this.lines, {this.widthDp = 120})
    : previous = '',
      current = kBubbleIdle,
      next = '';

  /// Builds what to show from the texts of the timed lines and the index the
  /// player says is active.
  ///
  /// [activeIndex] is the value of the very same stream the now-playing screen
  /// reads, so the two can never disagree. Null means "before the first line":
  /// the note is shown, with the first line as a preview of what is coming.
  factory BubblePayload.fromLines(
    List<String> texts,
    int? activeIndex,
    int lines, {
    required int widthDp,
  }) {
    if (texts.isEmpty) return BubblePayload.idle(lines, widthDp: widthDp);

    String at(int i) => i >= 0 && i < texts.length ? texts[i].trim() : '';

    if (activeIndex == null) {
      return BubblePayload(
        previous: '',
        current: kBubbleIdle,
        next: at(0),
        lines: lines,
        widthDp: widthDp,
      );
    }

    final current = at(activeIndex);
    return BubblePayload(
      previous: at(activeIndex - 1),
      // An empty timed line is an instrumental break, not a blank bubble.
      current: current.isEmpty ? kBubbleIdle : current,
      next: at(activeIndex + 1),
      lines: lines,
      widthDp: widthDp,
    );
  }

  String encode() => jsonEncode({
    'p': previous,
    'c': current,
    'n': next,
    'l': lines,
    'w': widthDp,
  });

  /// Null for anything that is not a payload (the overlay also receives plain
  /// control strings).
  static BubblePayload? tryDecode(Object? raw) {
    if (raw is! String) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      return BubblePayload(
        previous: '${map['p'] ?? ''}',
        current: '${map['c'] ?? kBubbleIdle}',
        next: '${map['n'] ?? ''}',
        lines: ((map['l'] as num?)?.toInt() ?? 2).clamp(1, 3),
        // Same default as the const constructor above: 120 dp.
        widthDp: (map['w'] as num?)?.toInt() ?? 120,
      );
    } on FormatException {
      return null;
    }
  }
}
