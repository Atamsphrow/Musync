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

/// One timed line, as the overlay needs it: milliseconds since track start
/// and the text to show. Plain maps keep the JSON small and the class
/// importable from both isolates without Flutter.
typedef TimedLineJson = Map<String, Object>;

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

  /// Identifies the track these lines belong to. The overlay uses it to tell
  /// a new song's payload from a correction for the current one.
  final String songId;

  /// Every timed line of the track: `{'ms': int, 't': String}`. The overlay
  /// runs its own ticker over these, so the lines keep advancing even when
  /// the main isolate is dead or its updates stop arriving in background.
  final List<TimedLineJson> timedLines;

  /// The line the main isolate computed as active, or null before the first
  /// line. The overlay anchors its own clock to this line's timestamp, so a
  /// correction from the main isolate re-syncs it instead of fighting it.
  final int? activeIndex;

  /// Audio position in milliseconds when the payload was built, and the wall
  /// clock (DateTime.now().millisecondsSinceEpoch) at that moment. The
  /// overlay extrapolates `positionMs + (now - sampledAtMs)` instead of
  /// anchoring to the active line's timestamp, so the shareData transmission
  /// delay no longer makes the bubble lag behind the sound on track change.
  /// Null when the position was unknown (idle payload).
  final int? positionMs;
  final int? sampledAtMs;

  /// The system font scale, baked in by the main isolate: the overlay runs in
  /// a separate engine without the system MediaQuery, so the bubble would
  /// otherwise ignore the user's text size (or clip text measured smaller).
  final double textScaleFactor;

  /// Lyrics appearance, baked in by the main isolate for the same reason:
  /// the overlay cannot read the app's settings. Font scale from the size
  /// picker, italic flag, serif flag, and the resolved active-line color
  /// (the bubble has its own color choice, independent from the player).
  final double fontScale;
  final bool italic;
  final bool serif;
  final int colorValue;

  const BubblePayload({
    required this.previous,
    required this.current,
    required this.next,
    required this.lines,
    required this.widthDp,
    this.songId = '',
    this.timedLines = const [],
    this.activeIndex,
    this.positionMs,
    this.sampledAtMs,
    this.textScaleFactor = 1.0,
    this.fontScale = 1.0,
    this.italic = true,
    this.serif = true,
    this.colorValue = 0xFFFFFFFF,
  });

  /// Nothing to sing: the bubble stays up, showing only the note.
  const BubblePayload.idle(
    this.lines, {
    this.widthDp = 120,
    this.textScaleFactor = 1.0,
    this.fontScale = 1.0,
    this.italic = true,
    this.serif = true,
    this.colorValue = 0xFFFFFFFF,
  })  : previous = '',
        current = kBubbleIdle,
        next = '',
        songId = '',
        timedLines = const [],
        activeIndex = null,
        positionMs = null,
        sampledAtMs = null;

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
    String songId = '',
    List<TimedLineJson> timedLines = const [],
    int? positionMs,
    int? sampledAtMs,
    double textScaleFactor = 1.0,
    double fontScale = 1.0,
    bool italic = true,
    bool serif = true,
    int colorValue = 0xFFFFFFFF,
  }) {
    if (texts.isEmpty) {
      return BubblePayload.idle(
        lines,
        widthDp: widthDp,
        textScaleFactor: textScaleFactor,
        fontScale: fontScale,
        italic: italic,
        serif: serif,
        colorValue: colorValue,
      );
    }

    String at(int i) => i >= 0 && i < texts.length ? texts[i].trim() : '';

    if (activeIndex == null) {
      return BubblePayload(
        previous: '',
        current: kBubbleIdle,
        next: at(0),
        lines: lines,
        widthDp: widthDp,
        songId: songId,
        timedLines: timedLines,
        activeIndex: null,
        positionMs: positionMs,
        sampledAtMs: sampledAtMs,
        textScaleFactor: textScaleFactor,
        fontScale: fontScale,
        italic: italic,
        serif: serif,
        colorValue: colorValue,
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
      songId: songId,
      timedLines: timedLines,
      activeIndex: activeIndex,
      positionMs: positionMs,
      sampledAtMs: sampledAtMs,
      textScaleFactor: textScaleFactor,
      fontScale: fontScale,
      italic: italic,
      serif: serif,
      colorValue: colorValue,
    );
  }

  String encode() => jsonEncode({
    'p': previous,
    'c': current,
    'n': next,
    'l': lines,
    'w': widthDp,
    's': songId,
    't': timedLines,
    'a': activeIndex,
    'pos': positionMs,
    'sat': sampledAtMs,
    'tsf': textScaleFactor,
    'fs': fontScale,
    'it': italic,
    'se': serif,
    'cv': colorValue,
  });

  /// Null for anything that is not a payload (the overlay also receives plain
  /// control strings).
  static BubblePayload? tryDecode(Object? raw) {
    if (raw is! String) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final timed = map['t'];
      return BubblePayload(
        previous: '${map['p'] ?? ''}',
        current: '${map['c'] ?? kBubbleIdle}',
        next: '${map['n'] ?? ''}',
        lines: ((map['l'] as num?)?.toInt() ?? 2).clamp(1, 3),
        // Same default as the const constructor above: 120 dp.
        widthDp: (map['w'] as num?)?.toInt() ?? 120,
        songId: '${map['s'] ?? ''}',
        timedLines: timed is List
            ? [
                for (final e in timed)
                  if (e is Map)
                    {
                      'ms': (e['ms'] as num?)?.toInt() ?? 0,
                      't': '${e['t'] ?? ''}',
                    },
              ]
            : const [],
        activeIndex: (map['a'] as num?)?.toInt(),
        positionMs: (map['pos'] as num?)?.toInt(),
        sampledAtMs: (map['sat'] as num?)?.toInt(),
        textScaleFactor:
            ((map['tsf'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 3.0),
        fontScale: ((map['fs'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 3.0),
        italic: (map['it'] as bool?) ?? true,
        serif: (map['se'] as bool?) ?? true,
        colorValue: (map['cv'] as num?)?.toInt() ?? 0xFFFFFFFF,
      );
    } on FormatException {
      return null;
    }
  }
}
