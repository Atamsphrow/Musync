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
  StreamSubscription<dynamic>? _events;

  /// Last (width, lines) the window was actually sized to. -1 forces the
  /// first payload through.
  int _appliedWidth = -1;
  int _appliedLines = -1;

  @override
  void initState() {
    super.initState();
    _events = FlutterOverlayWindow.overlayListener.listen((event) {
      final next = BubblePayload.tryDecode(event);
      if (next != null && mounted) {
        setState(() => _payload = next);
        unawaited(_applySize(next));
      }
    });
    // Tells the app the engine is up, so it sends the current line now instead
    // of guessing how long the start takes.
    FlutterOverlayWindow.shareData('ready');
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  /// Sizes the window to the payload. Done here, in the overlay isolate, on
  /// purpose: the plugin's `resizeOverlay` handler lives on the overlay
  /// engine's channel, so calling it from the main isolate throws
  /// `MissingPluginException` and the bubble would keep its opening width
  /// forever.
  Future<void> _applySize(BubblePayload p) async {
    if (p.widthDp == _appliedWidth && p.lines == _appliedLines) return;
    try {
      await FlutterOverlayWindow.resizeOverlay(
        p.widthDp,
        bubbleHeightFor(p.lines),
        true,
      );
      _appliedWidth = p.widthDp;
      _appliedLines = p.lines;
    } catch (_) {
      // The next line will try again; the text is already showing.
    }
  }

  Future<void> _close() async {
    // Only the main isolate can reach the plugin's closeOverlay — the overlay
    // engine has no handler for that channel. And the service never replies to
    // the message, so awaiting it would hang here forever and the tap would do
    // nothing. Fire the signal and let the main isolate close the window.
    unawaited(FlutterOverlayWindow.shareData('closed'));
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    const dim = Color(0x99FFFFFF);

    Widget line(String text, {required bool active}) => Text(
      text,
      textAlign: TextAlign.center,
      maxLines: active ? 2 : 1,
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
