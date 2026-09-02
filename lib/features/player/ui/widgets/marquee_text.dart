/// Text that scrolls past when it is too long to fit.
///
/// The now-playing title is often a whole file name — `Mr SAYDA - MBA MARINA
/// ANIE (Official Video 2017)` — and an ellipsis hides exactly the part that
/// says which version of the track this is. Scrolling it means the whole name
/// can be read without shrinking the type or wrapping it over three lines.
///
/// Only scrolls when it has to: a title that fits stays put and centred, which
/// is most of them. Movement that serves no purpose is worse than none.
library;

import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  /// Pixels per second. Slow enough to read at a glance.
  final double speed;

  /// Blank space between the end of one pass and the start of the next, so the
  /// two do not run into each other as one word.
  final double gap;

  /// How long the start is held still before it moves off, and again at the end
  /// of a pass. Without it the first word is already gone by the time the eye
  /// reaches it.
  final Duration pause;

  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.speed = 32,
    this.gap = 64,
    this.pause = const Duration(seconds: 2),
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> {
  final ScrollController _controller = ScrollController();
  bool _running = false;

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new track starts its own pass from the beginning.
    if (oldWidget.text != widget.text) {
      _running = false;
      if (_controller.hasClients) _controller.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// One pass, then another, for as long as the widget lives.
  ///
  /// Driven by awaited animations rather than a repeating controller so the
  /// pauses at each end are part of the loop instead of a second timer to keep
  /// in step with it.
  Future<void> _start() async {
    if (_running || !mounted) return;
    _running = true;

    while (mounted && _controller.hasClients) {
      final extent = _controller.position.maxScrollExtent;
      // Nothing to scroll: the title fits. Stop for good rather than spin.
      if (extent <= 0) break;

      await Future<void>.delayed(widget.pause);
      if (!mounted || !_controller.hasClients) break;

      await _controller.animateTo(
        extent,
        duration: Duration(
          milliseconds: (extent / widget.speed * 1000).round(),
        ),
        curve: Curves.linear,
      );
      if (!mounted || !_controller.hasClients) break;

      await Future<void>.delayed(widget.pause);
      if (!mounted || !_controller.hasClients) break;

      // Back to the start in one step rather than scrolling backwards: reading
      // a title in reverse is not a thing anyone does.
      _controller.jumpTo(0);
    }

    _running = false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final fits = painter.width <= constraints.maxWidth;

        if (fits) {
          return Text(
            widget.text,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: widget.style,
          );
        }

        WidgetsBinding.instance.addPostFrameCallback((_) => _start());

        return SizedBox(
          height: painter.height,
          child: ListView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            // The finger can move it too, and stopping it under the finger is
            // the expected behaviour of anything that scrolls.
            physics: const ClampingScrollPhysics(),
            children: [
              Text(widget.text, maxLines: 1, style: widget.style),
              SizedBox(width: widget.gap),
              // A second copy so the tail meets the head instead of ending on
              // empty space.
              Text(widget.text, maxLines: 1, style: widget.style),
            ],
          ),
        );
      },
    );
  }
}
