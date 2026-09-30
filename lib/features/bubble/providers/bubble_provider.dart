/// Drives the floating lyrics bubble from the main isolate.
///
/// The bubble does not compute anything. It is fed, line by line, from
/// `currentLineIndexProvider` — the stream the now-playing screen reads — so it
/// cannot run late relative to it. Everything the bubble draws travels through
/// [FlutterOverlayWindow.shareData] as a small JSON string.
///
/// It is only ever started by the user, from the now-playing screen. Leaving
/// the app never starts it.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/bubble/data/bubble_payload.dart';
import 'package:musync/features/bubble/data/bubble_sizing.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BubbleStart { started, permissionDenied, failed }

class BubbleState {
  final bool active;

  /// 1 = active line only, 2 = active + next, 3 = previous + active + next.
  final int lines;

  const BubbleState({this.active = false, this.lines = 2});

  BubbleState copyWith({bool? active, int? lines}) =>
      BubbleState(active: active ?? this.active, lines: lines ?? this.lines);
}

final lyricsBubbleProvider =
    NotifierProvider<LyricsBubbleController, BubbleState>(
      LyricsBubbleController.new,
    );

class LyricsBubbleController extends Notifier<BubbleState> {
  static const String _prefsKey = 'bubble_lines';

  /// Distance from the top of the screen in dp: just below the status bar,
  /// like the bubble used to sit.
  static const double _kBubbleTopMarginDp = 28;

  final List<ProviderSubscription<Object?>> _feeds = [];
  StreamSubscription<dynamic>? _fromOverlay;
  String? _lastSent;

  /// Width the overlay window has now, in dp.
  int _width = kBubbleMinWidth;

  @override
  BubbleState build() {
    ref.onDispose(_detach);
    unawaited(_hydrate());
    return const BubbleState();
  }

  Future<void> _hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_prefsKey);
      if (saved != null) {
        state = state.copyWith(lines: saved.clamp(1, 3));
      }
      // The bubble outlives the screen that opened it: found again after the
      // app was reopened, it is picked back up rather than orphaned.
      if (await FlutterOverlayWindow.isActive()) {
        state = state.copyWith(active: true);
        _attach();
      }
    } catch (error) {
      DebugLog.instance.warning(
        'Bulle',
        'État de la bulle illisible',
        error: error,
      );
    }
  }

  /// Opens the bubble, asking for the "display over other apps" permission
  /// first. Called only from the button.
  Future<BubbleStart> start() async {
    if (state.active) return BubbleStart.started;
    try {
      var granted = await FlutterOverlayWindow.isPermissionGranted();
      if (!granted) {
        // Opens the system page and answers once it comes back.
        granted = await FlutterOverlayWindow.requestPermission() ?? false;
      }
      if (!granted) return BubbleStart.permissionDenied;

      // Opened at the width of what is being sung right now, so it does not
      // start wide and shrink.
      final screenWidth = _screenWidthDp();
      _width = _payload().widthDp;

      // flutter_overlay_window 0.5.0 reads the width/height given here as raw
      // pixels in onStartCommand (dp values would shrink the window to a
      // postage stamp), while moveOverlay/resizeOverlay do convert dp to px.
      // So the initial size is sent pre-converted to pixels, and the position
      // is given explicitly in dp: the default path feeds -statusBarHeightPx()
      // — already pixels — through dpToPx a second time, which parks the
      // window fully off-screen with a top alignment. That is why only the
      // "Paroles flottantes affichées" notification ever appeared, never the
      // bubble itself.
      final density = _screenDensity();
      final xDp = ((screenWidth - _width) / 2).clamp(0.0, screenWidth);
      await FlutterOverlayWindow.showOverlay(
        width: (_width * density).round(),
        height: (bubbleHeightFor(state.lines) * density).round(),
        alignment: OverlayAlignment.topCenter,
        enableDrag: true,
        positionGravity: PositionGravity.none,
        overlayTitle: 'Musync',
        overlayContent: 'Paroles flottantes affichées',
        startPosition: OverlayPosition(xDp, _kBubbleTopMarginDp),
      );
    } catch (error, stack) {
      DebugLog.instance.error(
        'Bulle',
        'Ouverture de la bulle impossible',
        error: error,
        stackTrace: stack,
      );
      return BubbleStart.failed;
    }

    state = state.copyWith(active: true);
    _attach();
    // The overlay announces itself once its engine is up ('ready'), which is
    // the reliable moment to send the first line. This is the fallback for a
    // message that got lost.
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 700), _forcePush),
    );
    return BubbleStart.started;
  }

  Future<void> stop() async {
    _detach();
    state = state.copyWith(active: false);
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (error) {
      DebugLog.instance.warning(
        'Bulle',
        'Fermeture de la bulle impossible',
        error: error,
      );
    }
  }

  Future<void> setLines(int lines) async {
    final clamped = lines.clamp(1, 3);
    if (clamped == state.lines) return;
    state = state.copyWith(lines: clamped);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsKey, clamped);
      if (state.active) {
        // More or fewer lines change what is widest as well as how tall. The
        // new size travels inside the payload and the overlay applies it.
        _forcePush();
      }
    } catch (error) {
      DebugLog.instance.warning(
        'Bulle',
        'Réglage de la bulle non appliqué',
        error: error,
      );
    }
  }

  // ---- feed -------------------------------------------------------------

  void _attach() {
    if (_feeds.isNotEmpty) return;
    // The same providers the now-playing screen watches. Listening keeps the
    // autoDispose line stream alive for as long as the bubble is up.
    _feeds.add(
      ref.listen<AsyncValue<int?>>(
        currentLineIndexProvider,
        (_, _) => _push(),
      ),
    );
    _feeds.add(
      ref.listen(currentLyricsProvider, (_, _) => _push()),
    );
    _fromOverlay = FlutterOverlayWindow.overlayListener.listen(_onOverlay);
  }

  void _detach() {
    for (final feed in _feeds) {
      feed.close();
    }
    _feeds.clear();
    _fromOverlay?.cancel();
    _fromOverlay = null;
    _lastSent = null;
  }

  void _onOverlay(dynamic event) {
    if (event == 'ready') {
      _forcePush();
    } else if (event == 'closed') {
      // The × on the bubble itself. Only the main isolate can reach the
      // plugin's closeOverlay, so the overlay just signals and we close here.
      unawaited(stop());
    }
  }

  BubblePayload _payload() {
    final synced = ref.read(currentLyricsProvider).valueOrNull?.synced;
    final screenWidth = _screenWidthDp();
    // The width is measured here, from the same texts the bubble draws, and
    // travels inside the payload: the overlay isolate applies it itself.
    final base = synced == null || synced.isEmpty
        ? BubblePayload.idle(state.lines)
        : BubblePayload.fromLines(
            [for (final line in synced.lines) line.text],
            ref.read(currentLineIndexProvider).valueOrNull,
            state.lines,
            widthDp: 0, // Replaced by the measurement below.
          );
    return BubblePayload(
      previous: base.previous,
      current: base.current,
      next: base.next,
      lines: base.lines,
      widthDp: bubbleWidthFor(base, screenWidth),
    );
  }

  void _forcePush() {
    _lastSent = null;
    _push();
  }

  void _push() {
    if (!state.active) return;
    final payload = _payload();
    final data = payload.encode();
    // Same payload as last time (texts, lines and width): nothing to say,
    // and the stream ticks often.
    if (data == _lastSent) return;
    _lastSent = data;

    unawaited(_send(data));
    // The bubble is draggable and the plugin lets it wander off the screen.
    // Pulled back inside on every new line; a drag that stays on screen is
    // left exactly where the finger put it.
    unawaited(_keepOnScreen(payload.widthDp, payload.lines));
  }

  /// Moves the bubble back fully on screen when it drifted (or was dragged)
  /// past an edge. `moveOverlay`/`getOverlayPosition` are on the plugin's
  /// main-isolate channel, so this runs here — the overlay could not do it.
  Future<void> _keepOnScreen(int widthDp, int lines) async {
    try {
      final pos = await FlutterOverlayWindow.getOverlayPosition();
      final maxX = math.max(0.0, _screenWidthDp() - widthDp);
      final maxY = math.max(
        0.0,
        _screenHeightDp() - bubbleHeightFor(lines),
      );
      final x = pos.x.clamp(0.0, maxX);
      final y = pos.y.clamp(0.0, maxY);
      if (x != pos.x || y != pos.y) {
        await FlutterOverlayWindow.moveOverlay(OverlayPosition(x, y));
      }
    } catch (error) {
      DebugLog.instance.warning(
        'Bulle',
        'Recentrage de la bulle impossible',
        error: error,
      );
    }
  }

  /// Width of the screen in dp. The overlay is sized in the same unit.
  double _screenWidthDp() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return 360;
    final view = views.first;
    return view.physicalSize.width / view.devicePixelRatio;
  }

  /// Height of the screen in dp, for keeping the bubble on screen.
  double _screenHeightDp() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return 640;
    final view = views.first;
    return view.physicalSize.height / view.devicePixelRatio;
  }

  /// Screen density. Only the initial overlay size goes through as raw
  /// pixels (see start()); resizes are converted by the plugin itself.
  double _screenDensity() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return 1;
    return views.first.devicePixelRatio;
  }

  Future<void> _send(String data) async {
    try {
      await FlutterOverlayWindow.shareData(data);
    } catch (error) {
      DebugLog.instance.warning(
        'Bulle',
        'Envoi à la bulle impossible',
        error: error,
      );
    }
  }
}
