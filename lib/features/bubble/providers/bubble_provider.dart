/// Drives the floating lyrics bubble from the main isolate.
///
/// The bubble does not compute anything. It is fed, line by line, from
/// `currentLineIndexProvider` — the stream the now-playing screen reads — so it
/// cannot run late relative to it. Everything the bubble draws travels through
/// `FlutterOverlayWindow.shareData` as a small JSON string.
///
/// It is only ever started by the user, from the now-playing screen. Leaving
/// the app never starts it.
///
/// Visibility rules: the overlay window itself is shown only while the bubble
/// is enabled, something is actually playing, and the now-playing screen —
/// which already shows the synced lyrics — is not visible. Every rule change
/// funnels through [_syncOverlayVisibility].
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/bubble/data/bubble_payload.dart';
import 'package:musync/features/bubble/data/bubble_sizing.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
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

  final List<ProviderSubscription<Object?>> _feeds = [];
  StreamSubscription<dynamic>? _fromOverlay;
  String? _lastSent;

  /// Width the overlay window has now, in dp.
  int _width = kBubbleMinWidth;

  /// Whether the overlay window is up, tracked locally. The × on the bubble
  /// closes it natively (see the vendored plugin) and reports back through
  /// 'closed', so this is re-synced there too.
  bool _overlayUp = false;

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
      // app was reopened, it is picked back up rather than orphaned — unless
      // the visibility rules say it should not be up, in which case the sync
      // below closes it.
      if (await FlutterOverlayWindow.isActive()) {
        state = state.copyWith(active: true);
        _overlayUp = true;
        _attach();
        _syncOverlayVisibility();
      }
    } catch (error) {
      DebugLog.instance.warning(
        'Bulle',
        'État de la bulle illisible',
        error: error,
      );
    }
  }

  /// Enables the bubble, asking for the "display over other apps" permission
  /// first. Called only from the button. The window itself appears only when
  /// the visibility rules allow it — never on the now-playing screen, never
  /// while paused.
  Future<BubbleStart> start() async {
    if (state.active) return BubbleStart.started;
    try {
      var granted = await FlutterOverlayWindow.isPermissionGranted();
      if (!granted) {
        // Opens the system page and answers once it comes back.
        granted = await FlutterOverlayWindow.requestPermission() ?? false;
      }
      if (!granted) return BubbleStart.permissionDenied;
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
    _syncOverlayVisibility();
    return BubbleStart.started;
  }

  Future<void> stop() async {
    _detach();
    state = state.copyWith(active: false);
    _syncOverlayVisibility();
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
    _feeds.add(ref.listen(currentLyricsProvider, (_, _) => _push()));
    // A new track pushes right away: while its lyrics load, the provider
    // still holds the previous track's value, and without this the bubble
    // would sit frozen on the old song's last line.
    _feeds.add(ref.listen(currentSongProvider, (_, _) => _forcePush()));
    _feeds.add(
      ref.listen(playerStateProvider, (_, _) => _syncOverlayVisibility()),
    );
    _feeds.add(
      ref.listen(
        playerScreenVisibleProvider,
        (_, _) => _syncOverlayVisibility(),
      ),
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
      // The × on the bubble: it already closed itself natively (the vendored
      // plugin answers on the overlay's own channel); this just syncs the
      // state so the toggle and the visibility rules agree.
      _overlayUp = false;
      unawaited(stop());
    }
  }

  // ---- visibility -------------------------------------------------------

  bool get _playing =>
      ref.read(playerStateProvider).valueOrNull?.playing ?? false;

  bool get _playerVisible => ref.read(playerScreenVisibleProvider);

  /// Opens or closes the overlay window so that it matches the rules: shown
  /// only when enabled, playing, and away from the now-playing screen.
  void _syncOverlayVisibility() {
    final shouldShow = state.active && _playing && !_playerVisible;
    if (shouldShow == _overlayUp) return;
    _overlayUp = shouldShow;
    unawaited(shouldShow ? _openOverlay() : _closeOverlayNow());
  }

  /// Opens the overlay window at the width of what is being sung right now,
  /// so it does not start wide and shrink — centered on the screen, where it
  /// stays: the vendored plugin clamps every drag, move and resize.
  Future<void> _openOverlay() async {
    try {
      final screenWidth = _screenWidthDp();
      final screenHeight = _screenHeightDp();
      // Opened at the width of what is being sung right now.
      _width = _payload().widthDp;
      final height = bubbleHeightFor(state.lines);

      // flutter_overlay_window reads the width/height given here as raw
      // pixels in onStartCommand (dp values would shrink the window to a
      // postage stamp), while moveOverlay/resizeOverlay do convert dp to px.
      // So the initial size is sent pre-converted to pixels, and the position
      // is given explicitly in dp with a top-left gravity, making it literal:
      // true center of the screen.
      final density = _screenDensity();
      final xDp = (screenWidth - _width) / 2;
      final yDp = (screenHeight - height) / 2;
      await FlutterOverlayWindow.showOverlay(
        width: (_width * density).round(),
        height: (height * density).round(),
        alignment: OverlayAlignment.topLeft,
        enableDrag: true,
        positionGravity: PositionGravity.none,
        overlayTitle: 'Musync',
        overlayContent: 'Paroles flottantes affichées',
        startPosition: OverlayPosition(xDp, yDp),
      );
    } catch (error, stack) {
      _overlayUp = false;
      DebugLog.instance.error(
        'Bulle',
        'Ouverture de la bulle impossible',
        error: error,
        stackTrace: stack,
      );
      return;
    }
    // The overlay announces itself once its engine is up ('ready'), which is
    // the reliable moment to send the first line. This is the fallback for a
    // message that got lost.
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        if (_overlayUp) _forcePush();
      }),
    );
  }

  Future<void> _closeOverlayNow() async {
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
      }
    } catch (error) {
      DebugLog.instance.warning(
        'Bulle',
        'Fermeture de la bulle impossible',
        error: error,
      );
    }
  }

  // ---- payload ----------------------------------------------------------

  BubblePayload _payload() {
    final screenWidth = _screenWidthDp();
    // Only fresh data. While the next track's lyrics load — or when the load
    // failed — the provider still exposes the previous track's value, and
    // sampling it with the new position pins the bubble on the old song's
    // last line forever. Stale is worse than empty: show the idle note.
    final lyrics = ref.read(currentLyricsProvider);
    final synced = (!lyrics.isLoading && !lyrics.hasError)
        ? lyrics.valueOrNull?.synced
        : null;
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
  }

  /// Width of the screen in dp. The overlay is sized in the same unit.
  double _screenWidthDp() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return 360;
    final view = views.first;
    return view.physicalSize.width / view.devicePixelRatio;
  }

  /// Height of the screen in dp, for the centered opening position.
  double _screenHeightDp() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return 640;
    final view = views.first;
    return view.physicalSize.height / view.devicePixelRatio;
  }

  /// Screen density. Only the initial overlay size goes through as raw
  /// pixels (see _openOverlay()); resizes are converted by the plugin itself.
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
