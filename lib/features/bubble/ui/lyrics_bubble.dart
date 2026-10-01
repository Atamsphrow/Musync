/// The floating bubble itself: what is drawn over other apps.
///
/// This runs in a separate isolate started by `overlayMain` (see main.dart), so
/// it shares no state with the app — no providers, no player. It only listens
/// for the small JSON strings the main isolate sends, and draws the last one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:musync/features/bubble/data/bubble_payload.dart';
import 'package:musync/features/bubble/data/bubble_sizing.dart';

class LyricsBubbleApp extends StatelessWidget {
  const LyricsBubbleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: const Material(
        color: Colors.transparent,
        child: _LyricsBubble(),
      ),
    );
  }
}

class _LyricsBubble extends StatefulWidget {
  const _LyricsBubble();

  @override
  State<_LyricsBubble> createState() => _LyricsBubbleState();
}

class _LyricsBubbleState extends State<_LyricsBubble> {
  BubblePayload _payload = const BubblePayload.idle(2);

  /// How many visual lines the active lyric needs; long lines grow the
  /// bubble instead of being squeezed into two.
  int _activeLines = 2;
  StreamSubscription<dynamic>? _events;

  /// Independent line ticker. The main isolate drives the bubble while it is
  /// alive, but Android may kill it in background while the overlay service
  /// survives — and then the bubble would sit frozen on the last line it was
  /// told about. So the overlay advances the lines itself over the timed
  /// lines the main isolate sent: its own clock, no dependency. Main-isolate
  /// payloads remain the authority and re-anchor this clock when they arrive.
  Timer? _ticker;
  List<TimedLineJson> _timed = const [];
  String _timedSongId = '';
  int _anchorMs = 0;
  DateTime _anchorTime = DateTime.now();
  int? _shownIndex;

  /// Last (width, lines, active lines) the window was actually sized to.
  /// -1 forces the first payload through.
  int _appliedWidth = -1;
  int _appliedLines = -1;
  int _appliedActiveLines = -1;

  @override
  void initState() {
    super.initState();
    _events = FlutterOverlayWindow.overlayListener.listen((event) {
      final next = BubblePayload.tryDecode(event);
      if (next != null && mounted) {
        _adoptPayload(next);
      }
    });
    // Own clock for the lines: 5 ticks a second is plenty for text, and
    // keeps the bubble moving when the main isolate is gone.
    _ticker = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _tick(),
    );
    // Tells the app the engine is up, so it sends the current line now instead
    // of guessing how long the start takes.
    _signal('ready');
  }

  /// Fire-and-forget over the message bridge: even though the vendored plugin
  /// answers both ways now, the app may simply be gone.
  void _signal(String message) {
    Future<void> send() async {
      try {
        await FlutterOverlayWindow.shareData(message);
      } catch (_) {
        // Best effort only.
      }
    }

    unawaited(send());
  }

  /// Takes a payload from the main isolate: draws it now, and anchors the
  /// independent ticker to it. A new song replaces the timed lines; a line
  /// correction for the current song just re-syncs the clock.
  void _adoptPayload(BubblePayload next) {
    if (!mounted) return;
    setState(() {
      _payload = next;
      _activeLines = bubbleActiveLinesFor(
        next.current,
        next.widthDp.toDouble(),
      );
    });
    unawaited(_applySize(next, _activeLines));

    if (next.timedLines.isNotEmpty) {
      _timed = next.timedLines;
      _timedSongId = next.songId;
    } else if (next.songId != _timedSongId) {
      _timed = const [];
      _timedSongId = next.songId;
    }
    final idx = next.activeIndex;
    _shownIndex = idx;
    final posMs = next.positionMs;
    final satMs = next.sampledAtMs;
    if (posMs != null && satMs != null) {
      // Real audio position, extrapolated to now: the shareData flight time
      // no longer makes the bubble lag behind the sound on track change.
      _anchorMs = posMs;
      _anchorTime = DateTime.fromMillisecondsSinceEpoch(satMs);
    } else {
      _anchorMs = idx != null && idx >= 0 && idx < _timed.length
          ? (_timed[idx]['ms'] as int? ?? 0)
          : 0;
      _anchorTime = DateTime.now();
    }
  }

  /// Advances the shown line on the overlay's own clock. Only moves forward
  /// through the timed lines; anything the main isolate sends re-anchors via
  /// [_adoptPayload] and wins.
  void _tick() {
    if (!mounted || _timed.isEmpty) return;
    final posMs =
        _anchorMs + DateTime.now().difference(_anchorTime).inMilliseconds;
    final idx = _lineAt(posMs);
    if (idx == _shownIndex) return;
    _shownIndex = idx;
    final p = _payload;
    String at(int i) =>
        i >= 0 && i < _timed.length ? '${_timed[i]['t'] ?? ''}'.trim() : '';
    final current = at(idx ?? -1);
    final next = BubblePayload(
      previous: at((idx ?? 0) - 1),
      current: current.isEmpty ? kBubbleIdle : current,
      next: at((idx ?? -1) + 1),
      lines: p.lines,
      widthDp: p.widthDp,
      songId: p.songId,
      timedLines: p.timedLines,
      activeIndex: idx,
    );
    setState(() {
      _payload = next;
      _activeLines = bubbleActiveLinesFor(
        next.current,
        next.widthDp.toDouble(),
      );
    });
    unawaited(_applySize(next, _activeLines));
    // Re-anchor: the clock now runs from this line's timestamp, so drift
    // cannot accumulate across lines.
    _anchorMs = idx != null && idx >= 0 && idx < _timed.length
        ? (_timed[idx]['ms'] as int? ?? 0)
        : 0;
    _anchorTime = DateTime.now();
  }

  /// Index of the last timed line at or before [posMs], or null before the
  /// first line. Binary search: the list arrives sorted by timestamp.
  int? _lineAt(int posMs) {
    int low = 0;
    int high = _timed.length - 1;
    int? result;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final ms = _timed[mid]['ms'] as int? ?? 0;
      if (ms <= posMs) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _events?.cancel();
    super.dispose();
  }

  /// Sizes the window to the payload. Done here, in the overlay isolate, on
  /// purpose: the plugin's `resizeOverlay` handler lives on the overlay
  /// engine's channel, so calling it from the main isolate throws
  /// `MissingPluginException` and the bubble would keep its opening width
  /// forever. The width is fixed (one steady pill); the height grows when a
  /// long active line needs more than the default two visual lines.
  Future<void> _applySize(BubblePayload p, int activeLines) async {
    if (p.widthDp == _appliedWidth &&
        p.lines == _appliedLines &&
        activeLines == _appliedActiveLines) {
      return;
    }
    try {
      await FlutterOverlayWindow.resizeOverlay(
        p.widthDp,
        bubbleHeightForActiveLines(p.lines, activeLines),
        true,
      );
      _appliedWidth = p.widthDp;
      _appliedLines = p.lines;
      _appliedActiveLines = activeLines;
    } catch (_) {
      // The next line will try again; the text is already showing.
    }
  }

  Future<void> _close() async {
    // Tell the main isolate FIRST, while this engine is still alive: it syncs
    // its state through 'closed', so the Lecture en cours toggle turns off as
    // well. Awaited with a timeout — when the app is gone there is nobody to
    // answer, and the bubble must still close now.
    try {
      await FlutterOverlayWindow.shareData('closed').timeout(
        const Duration(seconds: 1),
      );
    } catch (_) {
      // Best effort only.
    }
    // Then close natively on the overlay engine's own channel. This tears the
    // engine down (the service stops itself), so anything sent after it would
    // never go out — that was the dead × toggle.
    try {
      await FlutterOverlayWindow.closeOverlayFromOverlay();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    const dim = Color(0x99FFFFFF);

    Widget line(String text, {required bool active}) => Text(
      text,
      textAlign: TextAlign.center,
      // The active line may take as many visual lines as it needs; the
      // bubble grows with it. Neighbours stay on one.
      maxLines: active ? _activeLines : 1,
      overflow: TextOverflow.ellipsis,
      // The very styles the width was measured with (bubble_sizing.dart).
      style: (active ? kBubbleActiveStyle : kBubbleNeighbourStyle).copyWith(
        color: active ? Colors.white : dim,
      ),
    );

    return Container(
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xE6121216),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (p.lines == 3 && p.previous.isNotEmpty)
                  line(p.previous, active: false),
                line(p.current, active: true),
                if (p.lines >= 2 && p.next.isNotEmpty)
                  line(p.next, active: false),
              ],
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: GestureDetector(
              onTap: _close,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.close, size: 18, color: dim),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
