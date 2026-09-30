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

  @override
  void initState() {
    super.initState();
    _events = FlutterOverlayWindow.overlayListener.listen((event) {
      final next = BubblePayload.tryDecode(event);
      if (next != null && mounted) setState(() => _payload = next);
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

  Future<void> _close() async {
    await FlutterOverlayWindow.shareData('closed');
    await FlutterOverlayWindow.closeOverlay();
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
