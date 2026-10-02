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

import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/bubble/data/bubble_payload.dart';
import 'package:musync/features/bubble/data/bubble_sizing.dart';
import 'package:musync/features/library/data/models/song.dart';
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

/// Whether a position sample taken after a track change is still the
/// previous track's stale tail.
///
/// Right after an automatic track change the platform may keep reporting
/// the old track's tail for a beat (just_audio extrapolates from the last
/// playback event and clamps to the old duration). Such a sample sits in
/// the clamp zone of the previous duration; a sample anywhere else means
/// the platform already confirmed the new track and the guard can disarm.
///
/// The guard only arms for a previous track longer than 10 s: with a short
/// tail any position of the new track could sit in the zone and the guard
/// would never disarm.
///
/// The guard is also time-bound: [armedAtMs]/[nowMs] let the caller say when
/// the track changed. Past [staleTailGuardWindowMs] the platform has confirmed
/// the new track, so a sample still sitting in the old zone is a deliberate
/// user seek there — not the platform's stale extrapolation — and must be
/// trusted. Without the bound, seeking the new track into the old track's
/// tail zone kept the bubble on the idle note indefinitely.
const int staleTailGuardWindowMs = 2000;

@visibleForTesting
bool isStaleTailSample(
  int? prevTailMs,
  int positionMs, {
  int? armedAtMs,
  int? nowMs,
}) {
  if (prevTailMs == null || prevTailMs <= 10000) return false;
  if (armedAtMs != null && nowMs != null) {
    if (nowMs - armedAtMs > staleTailGuardWindowMs) return false;
  }
  return positionMs >= prevTailMs - 3000 && positionMs <= prevTailMs + 2000;
}

class LyricsBubbleController extends Notifier<BubbleState> {
  static const String _prefsKey = 'bubble_lines';

  final List<ProviderSubscription<Object?>> _feeds = [];
  StreamSubscription<dynamic>? _fromOverlay;
  String? _lastSent;

  /// Subscription to the 60 Hz line index, alive only while playing. In pause
  /// the bubble is hidden (product rule) and the position is frozen, so
  /// listening would wake the main isolate 60x/s for nothing and keep the
  /// CPU from sleeping. Managed by [_syncLineFeed], not [_feeds].
  ProviderSubscription<AsyncValue<int?>>? _lineFeed;

  /// The song whose timed lines the overlay already holds. The overlay keeps
  /// its own copy and ticks on its own clock; re-sending 100k lines on every
  /// line change would rebuild multi-MB payloads for nothing. A fresh song
  /// id re-sends them once.
  String? _timedLinesSentFor;

  /// Duration (ms) of the track playing before the current one. Right after
  /// an automatic track change the platform may still report the previous
  /// track's tail for a beat — just_audio extrapolates from the last
  /// playback event and clamps to the old duration. A position sample in
  /// that zone belongs to the old track; neither it nor the line derived
  /// from it can be trusted for the new one.
  int? _prevTailMs;

  /// When the stale-tail guard was armed (epoch ms). See [isStaleTailSample].
  int? _prevTailArmedAtMs;

  /// Whether the overlay window is up, tracked locally. The × on the bubble
  /// closes it natively (see the vendored plugin) and reports back through
  /// 'closed', so this is re-synced there too.
  bool _overlayUp = false;

  /// When the overlay was last brought up. Guards [reconcile]: a bubble that
  /// is still opening must not be mistaken for a bubble that is gone.
  DateTime? _overlayUpSince;

  /// When an overlay open was last requested. A close arriving on the heels
  /// of an open must let the open reach the platform first: closing early is
  /// a no-op (`isActive()` still false) and the open then lands afterwards,
  /// orphaning the bubble with the toggle OFF.
  DateTime? _lastOpenRequestAt;

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
      // app was reopened, it is picked back up rather than orphaned. The
      // player-state feed attached below drives the first visibility sync
      // once just_audio reports in — syncing now would read "not playing"
      // from a provider that has not loaded yet and pointlessly close and
      // reopen the bubble.
      if (await FlutterOverlayWindow.isActive()) {
        state = state.copyWith(active: true);
        _overlayUp = true;
        _overlayUpSince = DateTime.now();
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

  /// Serialises start/stop: the permission request is async, so a second tap
  /// while the first is still asking must not interleave a stop into a
  /// half-started bubble (or vice versa). Rapid taps resolve in order, and
  /// the last one wins.
  Future<void> _toggleQueue = Future.value();

  /// Enables the bubble, asking for the "display over other apps" permission
  /// first. Called only from the button. The window itself appears only when
  /// the visibility rules allow it — never on the now-playing screen, never
  /// while paused.
  Future<BubbleStart> start() {
    final next = _toggleQueue.then((_) => _startNow());
    _toggleQueue = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> stop() {
    final next = _toggleQueue.then((_) => _stopNow());
    _toggleQueue = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<BubbleStart> _startNow() async {
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

  Future<void> _stopNow() async {
    _detach();
    state = state.copyWith(active: false);
    _syncOverlayVisibility();
  }

  /// Re-checks the real overlay state against what this controller believes.
  /// Called when the app comes back to the foreground: the × may have been
  /// tapped while the 'closed' message could not reach the main isolate
  /// (backgrounded engine, lost message), which would leave the Lecture en
  /// cours toggle on for a bubble that is gone.
  Future<void> reconcile() async {
    if (!_overlayUp) return;
    // A bubble that is still opening must not be mistaken for one that is
    // gone: the check would run while the window is not up yet and kill it.
    final since = _overlayUpSince;
    if (since != null &&
        DateTime.now().difference(since) < const Duration(seconds: 5)) {
      return;
    }
    try {
      if (!await FlutterOverlayWindow.isActive()) {
        _overlayUp = false;
        _overlayUpSince = null;
        await stop();
      }
    } catch (_) {
      // A failed check keeps the current state: never close on a guess.
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
    if (_feeds.isNotEmpty || _fromOverlay != null) return;
    _feeds.add(
      ref.listen(currentLyricsProvider, (_, _) {
        _push();
        _syncOverlayVisibility();
      }),
    );
    // A new track pushes right away: while its lyrics load, the provider
    // still holds the previous track's value, and without this the bubble
    // would sit frozen on the old song's last line.
    _feeds.add(
      ref.listen(currentSongProvider, (previous, _) {
        // Arm the stale-tail guard: until the platform confirms the new
        // track (its position restarts near zero), a sample up at the old
        // duration is the previous track's tail, not the new song.
        _prevTailMs = (previous as Song?)?.duration;
        _prevTailArmedAtMs = DateTime.now().millisecondsSinceEpoch;
        _forcePush();
      }),
    );
    // Deferred via microtask: running synchronously inside Riverpod's
    // notification cycle can trigger "Concurrent modification during
    // iteration" when the visibility sync touches provider state.
    _feeds.add(
      ref.listen(
        playerStateProvider,
        (_, _) => Future.microtask(() {
          _syncOverlayVisibility();
          _syncLineFeed();
        }),
      ),
    );
    _feeds.add(
      ref.listen(
        playerScreenVisibleProvider,
        (_, _) => Future.microtask(_syncOverlayVisibility),
      ),
    );
    // Backgrounding the app does not change the route: HOME from Lecture en
    // cours must bring the bubble back, and returning must hide it again.
    _feeds.add(
      ref.listen(
        appForegroundProvider,
        (_, _) => Future.microtask(_syncOverlayVisibility),
      ),
    );
    _fromOverlay = FlutterOverlayWindow.overlayListener.listen(_onOverlay);
    // The line index is subscribed separately: it only lives while playing,
    // to stop the 60 Hz wakeups in pause.
    _syncLineFeed();
  }

  void _detach() {
    for (final feed in _feeds) {
      feed.close();
    }
    _feeds.clear();
    _lineFeed?.close();
    _lineFeed = null;
    _fromOverlay?.cancel();
    _fromOverlay = null;
    _lastSent = null;
  }

  /// Attaches the 60 Hz line-index feed while playing, drops it in pause.
  /// Runs deferred like [_syncOverlayVisibility]: touching subscriptions
  /// synchronously inside Riverpod's notification cycle risks "Concurrent
  /// modification during iteration".
  void _syncLineFeed() {
    if (_feeds.isEmpty && _fromOverlay == null) return;
    if (_playing) {
      _lineFeed ??= ref.listen<AsyncValue<int?>>(
        currentLineIndexProvider,
        (_, _) => _push(),
      );
    } else {
      _lineFeed?.close();
      _lineFeed = null;
    }
  }

  void _onOverlay(dynamic event) {
    if (event == 'ready') {
      _forcePush();
    } else if (event == 'closed') {
      // The × on the bubble: it already closed itself natively (the vendored
      // plugin answers on the overlay's own channel); this just syncs the
      // state so the toggle and the visibility rules agree.
      _overlayUp = false;
      _overlayUpSince = null;
      unawaited(stop());
    }
  }

  // ---- visibility -------------------------------------------------------

  bool get _playing =>
      ref.read(playerStateProvider).valueOrNull?.playing ?? false;

  bool get _playerVisible =>
      ref.read(playerScreenVisibleProvider) &&
      ref.read(appForegroundProvider);

  /// Whether the current song is confirmed to carry synced lyrics.
  /// Returns null while the answer is not known yet (lyrics still loading,
  /// load error, or the provider still holding the previous song): the
  /// bubble is left as-is instead of flickering on every track change.
  bool? _hasSyncedLyrics() {
    final song = ref.read(currentSongProvider);
    final lyrics = ref.read(currentLyricsProvider);
    if (lyrics.isLoading || lyrics.hasError) return null;
    if (lyrics.valueOrNull?.song?.id != song?.id) return null;
    final synced = lyrics.valueOrNull?.synced;
    return synced != null && synced.isNotEmpty;
  }

  /// Opens or closes the overlay window so that it matches the rules: shown
  /// only when enabled, playing, away from the now-playing screen, and the
  /// current song actually has synced lyrics to show. A floating note with
  /// nothing to say is just in the way, so a confirmed lyrics-less song
  /// hides the bubble instead of parking it on the idle note.
  void _syncOverlayVisibility() {
    if (_hasSyncedLyrics() == false) {
      if (_overlayUp) {
        _overlayUp = false;
        _overlayUpSince = null;
        unawaited(_closeOverlayNow());
      }
      return;
    }
    final shouldShow = state.active && _playing && !_playerVisible;
    if (shouldShow == _overlayUp) return;
    _overlayUp = shouldShow;
    if (!shouldShow) _overlayUpSince = null;
    unawaited(shouldShow ? _openOverlay() : _closeOverlayNow());
  }

  /// Opens the overlay window: a steady full-width pill near the top of the
  /// screen, horizontally centered, the lyric centered inside it. The
  /// vendored plugin clamps every drag, move and resize, so it stays there.
  Future<void> _openOverlay() async {
    _lastOpenRequestAt = DateTime.now();
    try {
      await _showOverlayNative();
    } catch (error, stack) {
      _overlayUp = false;
      _overlayUpSince = null;
      DebugLog.instance.error(
        'Bulle',
        'Ouverture de la bulle impossible',
        error: error,
        stackTrace: stack,
      );
      return;
    }
    _overlayUpSince = DateTime.now();
    // The overlay announces itself once its engine is up ('ready'), which is
    // the reliable moment to send the first line. This is the fallback for a
    // message that got lost.
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 700), () async {
        if (!_overlayUp) return;
        _forcePush();
        // A close requested just before this open can still be tearing down
        // natively (stopSelf is asynchronous): the platform then drops the
        // open silently while the plugin reports success, leaving the toggle
        // ON with no bubble. If the overlay never came up, try once more —
        // by now the teardown is done.
        try {
          if (!await FlutterOverlayWindow.isActive()) {
            if (!_overlayUp) return;
            await _showOverlayNative();
            _overlayUpSince = DateTime.now();
          }
        } catch (error) {
          DebugLog.instance.warning(
            'Bulle',
            'Réouverture de la bulle impossible',
            error: error,
          );
        }
      }),
    );
  }

  /// The raw platform open, factored out so the post-open check can retry it.
  Future<void> _showOverlayNative() async {
    final screenWidth = _screenWidthDp();
    final width = bubbleFixedWidth(screenWidth);
    final height = bubbleHeightFor(state.lines);

    // flutter_overlay_window reads the width/height given here as raw
    // pixels in onStartCommand (dp values would shrink the window to a
    // postage stamp), while moveOverlay/resizeOverlay do convert dp to px.
    // So the initial size is sent pre-converted to pixels, and the position
    // is given explicitly in dp with a top-left gravity, making it literal:
    // centered horizontally, just under the status bar.
    final density = _screenDensity();
    final xDp = (screenWidth - width) / 2;
    final yDp = _statusBarHeightDp() + 12;
    await FlutterOverlayWindow.showOverlay(
      width: (width * density).round(),
      height: (height * density).round(),
      alignment: OverlayAlignment.topLeft,
      enableDrag: true,
      positionGravity: PositionGravity.none,
      overlayTitle: 'Musync',
      overlayContent: 'Paroles flottantes affichées',
      startPosition: OverlayPosition(xDp, yDp),
    );
  }

  Future<void> _closeOverlayNow() async {
    try {
      // An open requested a beat ago may not have reached the platform yet
      // (startService only enqueues): closing now would be a no-op and the
      // open would land afterwards, orphaning the bubble with the toggle
      // OFF. Let the open land first, then close for real.
      final openAt = _lastOpenRequestAt;
      if (openAt != null) {
        final wait =
            const Duration(milliseconds: 600) - DateTime.now().difference(openAt);
        if (wait > Duration.zero) await Future.delayed(wait);
      }
      // The desired state may have flipped back while waiting (ON->OFF->ON):
      // only close when the bubble is still supposed to be down.
      if (_overlayUp) return;
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
    // failed — the provider still exposes the previous track's value, and the
    // song tag is the only thing that tells them apart. Sampling the old
    // song's lines with the new position pins the bubble on the old song's
    // last line forever. Stale is worse than empty: show the idle note.
    final song = ref.read(currentSongProvider);
    final lyrics = ref.read(currentLyricsProvider);
    final synced =
        (!lyrics.isLoading &&
            !lyrics.hasError &&
            lyrics.valueOrNull?.song?.id == song?.id)
        ? lyrics.valueOrNull?.synced
        : null;
    // One steady width, whatever the line (see bubble_sizing.dart).
    final widthDp = bubbleFixedWidth(screenWidth);
    // Timed lines for the overlay's own ticker: it advances them on its own
    // clock, so the bubble keeps moving even when this isolate is dead or
    // its updates stop arriving in background. Sent once per song — the
    // overlay caches them and later pushes only re-sync the clock — because
    // rebuilding and encoding up to 100k lines on every line change would
    // allocate multi-MB payloads repeatedly.
    final songId = '${song?.id ?? 0}';
    final timedLines = synced == null ||
            synced.isEmpty ||
            songId == _timedLinesSentFor
        ? const <TimedLineJson>[]
        : [
            for (final line in synced.lines)
              {
                'ms': line.timestamp?.inMilliseconds ?? 0,
                't': line.text,
              },
          ];
    // Only when the lines were actually included: a song whose lyrics load
    // after the first push must still get them on the next one.
    if (timedLines.isNotEmpty) _timedLinesSentFor = songId;
    var activeIndex = ref.read(currentLineIndexProvider).valueOrNull;
    // The exact audio position right now, with the wall clock. The overlay
    // extrapolates positionMs + (now - sampledAtMs), which cancels the
    // shareData transmission delay that made the bubble lag behind the sound
    // on track change.
    //
    // Sampled from the same synchronous getter the line stream uses
    // (AudioPlayerService.position extrapolates with the wall clock), NOT
    // from positionProvider: just_audio's positionStream ticks at only
    // 200 ms on long tracks, so a payload built on a line change mixed a
    // fresh line index (sampled every 16 ms) with a stale position. The
    // overlay re-anchored its ticker to that stale position and briefly
    // showed the previous line again before catching up — the abrupt
    // flicker. Same source, same instant: the two can no longer disagree.
    var positionMs =
        ref.read(audioPlayerServiceProvider).position.inMilliseconds;
    var sampledAtMs = DateTime.now().millisecondsSinceEpoch;
    // Stale-tail guard: right after a track change the platform may still
    // report the previous track's tail (see _prevTailMs). The active line
    // was derived from that same stale sample, so the payload claims
    // nothing: the bubble shows the idle note with the new song's first
    // line as preview, and the overlay's own ticker converges onto the real
    // line within a tick once the platform confirms the new track. Without
    // this the bubble flashed the new song's LAST line while its start was
    // playing — the lag felt at automatic track changes.
    if (isStaleTailSample(
      _prevTailMs,
      positionMs,
      armedAtMs: _prevTailArmedAtMs,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    )) {
      activeIndex = null;
      positionMs = -1;
      sampledAtMs = -1;
    } else {
      // The platform confirmed the new track: the position restarted (or the
      // guard's time window expired). Either way it can disarm.
      _prevTailMs = null;
      _prevTailArmedAtMs = null;
    }
    final textScaleFactor = _textScaleFactor();
    final base = synced == null || synced.isEmpty
        ? BubblePayload.idle(state.lines, textScaleFactor: textScaleFactor)
        : BubblePayload.fromLines(
            [for (final line in synced.lines) line.text],
            activeIndex,
            state.lines,
            widthDp: 0, // Replaced by the fixed width below.
            songId: songId,
            timedLines: timedLines,
            positionMs: positionMs < 0 ? null : positionMs,
            sampledAtMs: sampledAtMs < 0 ? null : sampledAtMs,
            textScaleFactor: textScaleFactor,
          );
    return BubblePayload(
      previous: base.previous,
      current: base.current,
      next: base.next,
      lines: base.lines,
      widthDp: widthDp,
      songId: base.songId,
      timedLines: base.timedLines,
      activeIndex: base.activeIndex,
      positionMs: base.positionMs,
      sampledAtMs: base.sampledAtMs,
      textScaleFactor: base.textScaleFactor,
    );
  }

  void _forcePush() {
    _lastSent = null;
    _timedLinesSentFor = null;
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

  /// The system font scale, baked into the payload: the overlay engine has no
  /// system MediaQuery of its own. This is the same source the framework's
  /// own SystemTextScaler reads. Clamped so a pathological setting cannot
  /// blow up the fixed-width layout (the height already adapts).
  double _textScaleFactor() {
    try {
      // ignore: deprecated_member_use
      return PlatformDispatcher.instance.textScaleFactor.clamp(0.5, 3.0);
    } catch (_) {
      return 1.0;
    }
  }

  /// Status bar height in dp, so the bubble opens just under it.
  double _statusBarHeightDp() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return 24;
    final view = views.first;
    return view.padding.top / view.devicePixelRatio;
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
