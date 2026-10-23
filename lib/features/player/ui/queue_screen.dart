import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/frame_probe.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/providers/named_queue_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';

/// The route for the player's live queue, as pushed by the ⋮ menu's
/// « File d'attente » entry: the ≡ handle moves a track (drag up/down)
/// or removes it (drag right), tap one to play it.
///
/// The page lives to the RIGHT of the player: it slides in from the
/// right, and a rightward swipe on the list takes it back — the page
/// follows the finger, the player reappears underneath (the route is
/// not opaque), and releasing far enough slides it the rest of the way
/// out before popping. The in-player panel is a different geometry
/// (it sits on the left) and keeps its leftward close.
Route<void> queueScreenRoute() {
  return PageRouteBuilder<void>(
    opaque: false,
    pageBuilder: (context, animation, secondaryAnimation) =>
        const QueueScreen(),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final offset = animation.drive(
        Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
      );
      // RepaintBoundary, like the player route: the page glides as an
      // already-rasterised texture instead of repainting with the slide.
      return SlideTransition(
        position: offset,
        child: RepaintBoundary(child: child),
      );
    },
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 250),
  );
}

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen>
    with SingleTickerProviderStateMixin {
  /// How far the page is dragged right by the return swipe.
  ///
  /// A notifier, NOT a double + setState: the drag reports an event per
  /// pointer move and the settle an update per frame, and a setState
  /// here rebuilt the whole screen — Scaffold, list, every visible
  /// row — for what is only a horizontal translation. The
  /// ValueListenableBuilder in [build] now moves just the Transform.
  final ValueNotifier<double> _dragOffset = ValueNotifier<double>(0);

  /// TEMPORARY diagnostic (the lag hunt): this screen's slow frames.
  FrameProbe? _openProbe;

  /// Drives the page out (on a committed return swipe) or back to rest.
  late final AnimationController _settleAnim;
  double _settleFrom = 0;
  double _settleTarget = 0;
  bool _settlePops = false;

  @override
  void initState() {
    super.initState();
    _settleAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _settleAnim.addListener(() {
      _dragOffset.value = _settleFrom +
          (_settleTarget - _settleFrom) *
              Curves.easeOutCubic.transform(_settleAnim.value);
    });
    _settleAnim.addStatusListener((status) {
      if (status != AnimationStatus.completed || !_settlePops) return;
      _settlePops = false;
      Navigator.of(context).pop();
    });
    _openProbe = FrameProbe.start('ouverture file', frames: 40);
  }

  @override
  void dispose() {
    _openProbe?.stop();
    _settleAnim.dispose();
    _dragOffset.dispose();
    super.dispose();
  }

  void _onReturnDragStart() => _settleAnim.stop();

  void _onReturnDragUpdate(double dx, double dy) {
    // Rightward only: the page follows the finger out; a leftward drag
    // on the list does nothing here.
    if (dx <= 0) return;
    _dragOffset.value = dx;
  }

  void _onReturnDragEnd(double dx, double velocityX) {
    final width = MediaQuery.sizeOf(context).width;
    final commit = dx >= 90 || velocityX >= 500;
    _settleFrom = _dragOffset.value;
    _settleTarget = commit ? width : 0;
    _settlePops = commit;
    _settleAnim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Built once per build and handed to the ValueListenableBuilder as
    // its child: a drag tick rebuilds only the Transform, never this
    // Scaffold or the list inside it.
    final page = Scaffold(
      appBar: AppBar(
        title: const Text('File d\u2019attente'),
      ),
      backgroundColor: scheme.surface,
      body: SafeArea(
        top: false,
        child: _AfterTransition(
          child: QueueListBody(
            onDragSwipeStart: _onReturnDragStart,
            onDragSwipeUpdate: _onReturnDragUpdate,
            onDragSwipeEnd: _onReturnDragEnd,
          ),
        ),
      ),
    );
    return ValueListenableBuilder<double>(
      valueListenable: _dragOffset,
      child: page,
      builder: (context, dx, child) =>
          Transform.translate(offset: Offset(dx, 0), child: child),
    );
  }
}

/// Shows [child] only once the route's entrance transition completes:
/// the queue list is this screen's heavy part, and building it during
/// the slide-in paid its layout on the very frames that should only
/// have been moving the page — the same disease the player screen's
/// lazy panel cured. The page enters with its title bar and an empty
/// body for ~300 ms, then the list appears.
class _AfterTransition extends StatefulWidget {
  const _AfterTransition({required this.child});

  final Widget child;

  @override
  State<_AfterTransition> createState() => _AfterTransitionState();
}

class _AfterTransitionState extends State<_AfterTransition> {
  bool _ready = false;
  Animation<double>? _animation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready || _animation != null) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      _ready = true;
      return;
    }
    _animation = animation..addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _ready = true);
    }
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_onStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _ready ? widget.child : const SizedBox.expand();
}

/// The queue content itself, without the Scaffold: shared by the [QueueScreen]
/// route and the now-playing screen's swipe-in panel.
class QueueListBody extends ConsumerStatefulWidget {
  /// Balayage horizontal sur la liste, rapporté à l'hôte : la liste
  /// elle-même ne navigue pas et ne déplace rien.
  ///
  /// Le geste n'est rapporté qu'une fois franchement horizontal (voir le
  /// suivi dans le State) : [onDragSwipeStart] au début, [onDragSwipeUpdate]
  /// avec le déplacement cumulé pendant le geste, [onDragSwipeEnd] avec le
  /// déplacement total et la vélocité horizontale au relâcher. Le panneau
  /// coulissant suit le doigt avec (comme le balayage aller), l'écran de
  /// file se contente de dépiler sa route à la fin.
  final VoidCallback? onDragSwipeStart;
  final void Function(double dx, double dy)? onDragSwipeUpdate;
  final void Function(double dx, double velocityX)? onDragSwipeEnd;

  const QueueListBody({
    super.key,
    this.onDragSwipeStart,
    this.onDragSwipeUpdate,
    this.onDragSwipeEnd,
  });

  @override
  ConsumerState<QueueListBody> createState() => _QueueListBodyState();
}

class _QueueListBodyState extends ConsumerState<QueueListBody>
    with SingleTickerProviderStateMixin {
  /// Row height before the first row has been measured.
  static const double _fallbackRowExtent = 72;

  /// The rows' real height, measured on a built row (see [_RowExtentProbe]).
  ///
  /// A two-line ListTile is nominally 72 dp, but text scaling and theme
  /// metrics move it — and every computation below multiplies the error by
  /// the track's index: a 4 dp miss lands the « aller au morceau en cours »
  /// jump four rows short at index 70, and wrongly shows or hides the
  /// button. Measuring removes the guess entirely.
  double _rowExtent = _fallbackRowExtent;
  bool _extentMeasured = false;

  void _reportRowExtent(double extent) {
    if (_reorderActive) return;
    if (extent <= 0 || (extent - _rowExtent).abs() < 0.5) return;
    _rowExtent = extent;
    if (!_extentMeasured) {
      _extentMeasured = true;
      // First real measurement: the open-on-current jump in initState ran
      // on the fallback estimate — redo it with the true row height.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrent(animated: false),
      );
    }
    _updateLocateButton();
  }

  final ScrollController _scrollController = ScrollController();

  /// True while a reorder drag is in flight. Extent reports are ignored
  /// then: the drag proxy is a second build of a row, and letting its
  /// (possibly distorted) measure feed back into [_rowExtent] mid-drag
  /// would rebuild the list under the user's finger.
  bool _reorderActive = false;

  /// Whether the « aller au morceau en cours » button shows: the current
  /// track is estimated outside the visible window.
  bool _showLocateButton = false;

  /// Ends the remove slide-out/slide-back animation.
  late final AnimationController _removeAnim;

  @override
  void initState() {
    super.initState();
    _removeAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _removeAnim.addListener(() {
      if (_removeSong == null) return;
      setState(() {
        _removeDx = _removeAnimFrom +
            (_removeAnimTarget - _removeAnimFrom) *
                Curves.easeOutCubic.transform(_removeAnim.value);
      });
    });
    _removeAnim.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      final song = _removeAnimSong;
      _removeAnimSong = null;
      _removeHold?.cancel();
      _removeHold = null;
      _removeSong = null;
      _removeDx = 0;
      if (mounted) setState(() {});
      if (_removeCommit && song != null) unawaited(_executeRemove(song));
    });
    _scrollController.addListener(_updateLocateButton);
    // Open on the current track: with a queue of thousands of songs,
    // landing at the top and hunting by hand is not a way in. A jump, not
    // an animation — the distance can be enormous.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToCurrent(animated: false),
    );
  }

  // ── Balayage horizontal sur la liste, rapporté à l'hôte ──
  //
  // Observed through a Listener, outside the gesture arena: the ≡
  // handle's drag listener owns the gestures that start on a row, so a
  // GestureDetector here would never win a leftward drag. The host is
  // only called once the drag is unmistakably horizontal — engaging
  // earlier would make the slide panel wobble along with every vertical
  // scroll of the list.
  int? _trackedPointer;
  double _swipeDx = 0;
  double _swipeDy = 0;
  bool _swipeEngaged = false;

  /// Displacement at engagement: updates are reported relative to it, so
  /// the host's follow starts at zero instead of jumping by the ~24 px
  /// the drag needed to prove itself horizontal. The end callback still
  /// gets the total displacement.
  double _engagedDx = 0;
  double _engagedDy = 0;
  VelocityTracker? _velocityTracker;

  /// Scroll offset when the tracked finger went down. A horizontal
  /// swipe must not scroll the list — not even the few pixels of
  /// vertical drift before the swipe proves itself — so at engagement
  /// the offset is restored to this and the scroll is held until the
  /// finger lifts (Musicolet behaves the same way).
  double _swipeStartPixels = 0;
  ScrollHoldController? _swipeHold;
  bool _swipeHoldActive = false;

  void _onPointerDown(PointerDownEvent event) {
    if (_trackedPointer != null) return;
    _trackedPointer = event.pointer;
    _swipeDx = 0;
    _swipeDy = 0;
    _swipeEngaged = false;
    _swipeStartPixels =
        _scrollController.hasClients ? _scrollController.position.pixels : 0;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _trackedPointer) return;
    // A gesture that starts on the ≡ handle belongs to the handle
    // (reorder or remove); it never drives the host's swipe.
    if (event.pointer == _handlePointer) return;
    _swipeDx += event.delta.dx;
    _swipeDy += event.delta.dy;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    if (!_swipeEngaged) {
      if (_swipeDx.abs() < 24 ||
          _swipeDx.abs() < 1.5 * _swipeDy.abs()) {
        return;
      }
      _swipeEngaged = true;
      _engagedDx = _swipeDx;
      _engagedDy = _swipeDy;
      _freezeScrollForSwipe();
      widget.onDragSwipeStart?.call();
    }
    widget.onDragSwipeUpdate?.call(
      _swipeDx - _engagedDx,
      _swipeDy - _engagedDy,
    );
  }

  /// Holds the list's scroll for the rest of the swipe and undoes the
  /// vertical drift accumulated before engagement.
  void _freezeScrollForSwipe() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    _swipeHold = position.hold(() {});
    if (position.pixels != _swipeStartPixels) {
      // The jump replaces the held activity — the hold is spent, and
      // cancelling its controller afterwards would touch a disposed
      // activity.
      position.jumpTo(_swipeStartPixels);
      _swipeHold = null;
      _swipeHoldActive = false;
    } else {
      _swipeHoldActive = true;
    }
  }

  void _releaseSwipeHold() {
    if (_swipeHoldActive) _swipeHold?.cancel();
    _swipeHold = null;
    _swipeHoldActive = false;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _trackedPointer) return;
    _trackedPointer = null;
    if (!_swipeEngaged) return;
    _swipeEngaged = false;
    _releaseSwipeHold();
    final velocity =
        _velocityTracker?.getVelocity().pixelsPerSecond.dx ?? 0;
    widget.onDragSwipeEnd?.call(_swipeDx, velocity);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _trackedPointer) return;
    _trackedPointer = null;
    if (!_swipeEngaged) return;
    _swipeEngaged = false;
    _releaseSwipeHold();
    // Settle whatever the drag was driving, as if released still.
    widget.onDragSwipeEnd?.call(_swipeDx, 0);
  }

  // ── Poignée ≡ : la direction décide, comme Musicolet ──
  //
  // Le drag framework ne démarre plus au pointer-down : les premiers
  // pixels disent où va le geste, et seulement alors —
  //   • franchement vertical : le reorder du framework démarre, depuis
  //     l'événement d'appui d'origine (démarrage différé, le même
  //     schéma que ReorderableDelayedDragStartListener) ;
  //   • franchement à droite : la ligne elle-même suit le doigt,
  //     rigidement, pendant que le défilement de la liste est tenu —
  //     au relâcher, passé le seuil elle finit de sortir et elle est
  //     retirée ; en dessous, elle revient à sa place.
  // Avant ce découpage, le proxy de reorder partait dans les deux axes
  // et le retrait attendait la fin de l'animation de dépôt pour
  // supprimer la ligne d'un coup — rien à voir avec Musicolet.
  static const double _handleDecisionSlop = 12;
  static const double _removeThreshold = 120;

  int? _handlePointer;
  PointerDownEvent? _handleDownEvent;
  BuildContext? _handleContext;
  Song? _handleSong;
  int _handleIndex = -1;
  double _handleDx = 0;
  double _handleDy = 0;
  bool _handleDecided = false;
  bool _handleReorder = false;

  /// The song being dragged right out, and its live X offset. The row
  /// is rendered translated by this much (see the item builder).
  Song? _removeSong;
  double _removeDx = 0;
  ScrollHoldController? _removeHold;
  double _removeAnimFrom = 0;
  double _removeAnimTarget = 0;
  bool _removeCommit = false;
  Song? _removeAnimSong;

  void _handleDragStart(
    PointerDownEvent event,
    Song song,
    int index,
    BuildContext handleContext,
  ) {
    if (_handlePointer != null || _removeAnim.isAnimating) return;
    _handlePointer = event.pointer;
    _handleDownEvent = event;
    _handleContext = handleContext;
    _handleSong = song;
    _handleIndex = index;
    _handleDx = 0;
    _handleDy = 0;
    _handleDecided = false;
    _handleReorder = false;
  }

  void _handleDragMove(PointerMoveEvent event) {
    if (event.pointer != _handlePointer) return;
    _handleDx += event.delta.dx;
    _handleDy += event.delta.dy;
    if (_handleReorder) return; // The framework owns the gesture now.
    if (_removeSong != null) {
      // Remove drag: the row follows the finger right, never back past
      // its slot.
      setState(() => _removeDx = _handleDx.clamp(0.0, double.infinity));
      return;
    }
    if (_handleDecided) return;
    final adx = _handleDx.abs();
    final ady = _handleDy.abs();
    if (adx < _handleDecisionSlop && ady < _handleDecisionSlop) return;
    _handleDecided = true;
    if (ady >= adx) {
      // Vertical: hand the gesture to the framework reorder, started
      // from the ORIGINAL down event. The sliver state takes ownership
      // of the recognizer (it registers the pointer and disposes it at
      // the end of the drag) — nothing to clean up here.
      final down = _handleDownEvent;
      final handleContext = _handleContext;
      if (down != null && handleContext != null && handleContext.mounted) {
        try {
          SliverReorderableList.maybeOf(handleContext)?.startItemDragReorder(
            index: _handleIndex,
            event: down,
            recognizer: ImmediateMultiDragGestureRecognizer(),
          );
          _handleReorder = true;
        } catch (_) {
          // The row vanished mid-gesture (queue mutated under the
          // finger): let the gesture die quietly.
        }
      }
    } else if (_handleDx > 0) {
      // Right: remove drag. Hold the list's scroll — the finger may
      // drift vertically, the list must not follow.
      final song = _handleSong;
      if (song == null) return;
      if (_scrollController.hasClients) {
        _removeHold = _scrollController.position.hold(() {});
      }
      setState(() {
        _removeSong = song;
        _removeDx = _handleDx;
      });
    }
    // Left from the handle: nothing of ours — the gesture just dies.
  }

  void _handleDragEnd(PointerUpEvent event) {
    if (event.pointer != _handlePointer) return;
    _handlePointer = null;
    _handleDownEvent = null;
    _handleContext = null;
    _handleSong = null;
    if (_removeSong != null) {
      _finishRemoveDrag(commit: _removeDx >= _removeThreshold);
    }
  }

  void _handleDragCancel(PointerCancelEvent event) {
    if (event.pointer != _handlePointer) return;
    _handlePointer = null;
    _handleDownEvent = null;
    _handleContext = null;
    _handleSong = null;
    if (_removeSong != null) _finishRemoveDrag(commit: false);
  }

  /// Ends a remove drag: past the threshold the row slides the rest of
  /// the way out and is removed when the slide completes; below it, it
  /// slides back to its slot. The removal itself runs from the
  /// animation's completion listener (see initState).
  void _finishRemoveDrag({required bool commit}) {
    if (_removeSong == null) return;
    _removeCommit = commit;
    _removeAnimSong = _removeSong;
    _removeAnimFrom = _removeDx;
    _removeAnimTarget = commit ? MediaQuery.sizeOf(context).width : 0;
    _removeAnim.forward(from: 0);
  }

  /// Retire [song] où qu'il soit rendu dans la file — le drag qui a
  /// déclenché le retrait peut aussi l'avoir réordonné entre-temps,
  /// donc jamais d'index capturé à l'avance. `identical` distingue deux
  /// occurrences du même morceau.
  Future<void> _executeRemove(Song song) async {
    final queue = ref.read(audioPlayerServiceProvider).queue;
    final index = queue.indexWhere((s) => identical(s, song));
    if (index < 0) return;
    await _remove(index, song);
  }

  @override
  void dispose() {
    _removeAnim.dispose();
    _swipeHold?.cancel();
    _removeHold?.cancel();
    _scrollController.removeListener(_updateLocateButton);
    _scrollController.dispose();
    super.dispose();
  }

  void _updateLocateButton() {
    if (!mounted || !_scrollController.hasClients) return;
    final service = ref.read(audioPlayerServiceProvider);
    final index = service.currentIndex;
    final show = index >= 0 &&
        index < service.queue.length &&
        _currentOutsideView(index);
    if (show != _showLocateButton) {
      setState(() => _showLocateButton = show);
    }
  }

  bool _currentOutsideView(int index) {
    final position = _scrollController.position;
    final top = index * _rowExtent;
    final bottom = top + _rowExtent;
    return bottom < position.pixels ||
        top > position.pixels + position.viewportDimension;
  }

  /// Brings the current track into view, centred when possible.
  ///
  /// Pure offset math, exact because the row height is measured rather
  /// than guessed. There is deliberately no `ensureVisible` step: it
  /// needed a GlobalKey on the current row, and a GlobalKey inside a
  /// reorderable row corrupts the drag — the proxy builds a second copy
  /// of the subtree, the key's element is stolen by the proxy, and the
  /// dragged copy of the playing track renders at a wrong height,
  /// overlapping its neighbours.
  Future<void> _scrollToCurrent({bool animated = true}) async {
    if (!mounted || !_scrollController.hasClients) return;
    final service = ref.read(audioPlayerServiceProvider);
    final index = service.currentIndex;
    if (index < 0 || index >= service.queue.length) return;
    final position = _scrollController.position;
    final target = (index * _rowExtent -
            position.viewportDimension / 2 +
            _rowExtent / 2)
        .clamp(0.0, position.maxScrollExtent);
    if ((position.pixels - target).abs() > _rowExtent) {
      if (animated) {
        await _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    }
    _updateLocateButton();
  }

  /// F6 hook: mirrors the player's queue into the active named queue, so the
  /// named queue stays an exact snapshot after a reorder/remove/play-next.
  Future<void> _syncActiveQueue() async {
    try {
      await ref.read(namedQueuesProvider.notifier).syncActiveFromPlayer();
    } catch (_) {
      // Best-effort: the queue mutation itself already succeeded.
    }
  }

  void _reorder(int oldIndex, int newIndex) {
    // Synchronous: the sliver animates the displaced rows from the
    // next frame, so the new order must be applied before returning —
    // awaiting the player mirror first is what made the rows jump instead
    // of sliding. The mirror and the named-queue sync follow in the
    // background.
    final moved = ref
        .read(audioPlayerServiceProvider)
        .reorderQueueSync(oldIndex, newIndex);
    if (mounted) setState(() {});
    if (moved == null) return;
    unawaited(_applyReorder(moved.$1, moved.$2));
  }

  Future<void> _applyReorder(int oldIndex, int newIndex) async {
    await ref
        .read(audioPlayerServiceProvider)
        .reorderQueueApply(oldIndex, newIndex);
    await _syncActiveQueue();
    if (mounted) setState(() {});
  }

  Future<void> _remove(int index, Song song) async {
    await ref.read(audioPlayerServiceProvider).removeFromQueue(index);
    await _syncActiveQueue();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('« ${song.title} » retiré de la file')),
    );
  }

  Future<void> _playAt(List<Song> queue, int index) async {
    await ref
        .read(audioPlayerServiceProvider)
        .playSong(queue[index], queue: queue, index: index);
    if (mounted) setState(() {});
  }

  String _formatDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final service = ref.watch(audioPlayerServiceProvider);
    // Rebuilds the highlight when playback moves on its own (notification,
    // lock screen, automatic advance) — the queue list itself only changes
    // through this screen's mutations, which call setState.
    ref.watch(currentIndexProvider);
    ref.watch(currentSongProvider);

    final queue = service.queue;
    final currentIndex = service.currentIndex;

    // Listener, hors gesture arena : il observe le balayage horizontal
    // sans voler leurs gestes aux lignes (la poignée ≡ garde les siens).
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Stack(
        children: [
          if (queue.isEmpty)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.queue_music_outlined,
                    size: 64,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'La file d\u2019attente est vide',
                    style: textTheme.titleMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Lancez un morceau depuis la bibliothèque\npour remplir la file.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            )
          else
            CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverReorderableList(
                  itemCount: queue.length,
                  onReorderStart: (_) => _reorderActive = true,
                  onReorderEnd: (_) => _reorderActive = false,
                  onReorderItem: _reorder,
                  itemBuilder: (context, index) {
                    final song = queue[index];
                    final isCurrent = index == currentIndex;
                    // `identityHashCode`: the service keeps the same Song
                    // instances across mutations, so this stays stable
                    // while remaining unique even if the same track is
                    // queued twice (Song equality is by id alone).
                    final key =
                        ValueKey('queue_${song.id}_${identityHashCode(song)}');
                    Widget row = _RowExtentProbe(
                      onExtent: _reportRowExtent,
                      child: Material(
                        color: isCurrent
                            ? scheme.primaryContainer.withValues(alpha: 0.45)
                            : Colors.transparent,
                        child: ListTile(
                          // La poignée fait tout, comme Musicolet : la
                          // direction du glisser décide — vertical pour
                          // déplacer, droite pour retirer (voir le suivi
                          // de la poignée dans le State).
                          leading: Listener(
                            onPointerDown: (e) =>
                                _handleDragStart(e, song, index, context),
                            onPointerMove: _handleDragMove,
                            onPointerUp: _handleDragEnd,
                            onPointerCancel: _handleDragCancel,
                            child: Icon(
                              Icons.drag_handle,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          title: Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyLarge?.copyWith(
                              color: isCurrent
                                  ? scheme.primary
                                  : scheme.onSurface,
                              fontWeight: isCurrent
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            '${song.artist} \u2022 ${song.album}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isCurrent)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Icon(
                                    Icons.graphic_eq_rounded,
                                    size: 18,
                                    color: scheme.primary,
                                    semanticLabel: 'Lecture en cours',
                                  ),
                                ),
                              Text(
                                _formatDuration(song.duration),
                                style: textTheme.labelMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          onTap: () => _playAt(queue, index),
                        ),
                      ),
                    );
                    // Remove drag in flight: the row itself slides right
                    // with the finger, over its emptied slot.
                    if (identical(song, _removeSong)) {
                      row = Transform.translate(
                        offset: Offset(_removeDx, 0),
                        child: row,
                      );
                    }
                    return KeyedSubtree(key: key, child: row);
                  },
                ),
              ],
            ),
          if (_showLocateButton && queue.isNotEmpty)
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.small(
                onPressed: () => _scrollToCurrent(),
                tooltip: 'Aller au morceau en cours',
                child: const Icon(Icons.my_location),
              ),
            ),
        ],
      ),
    );
  }
}

/// Reports the real height of a queue row once it is laid out.
///
/// Every row is the same two-line ListTile, so any row's measurement
/// serves all of them; the parent keeps the value and ignores repeats.
/// Measuring beats guessing: the nominal 72 dp is wrong as soon as text
/// scaling or theme metrics move, and a wrong guess misses the current
/// track by `index × error`.
class _RowExtentProbe extends StatefulWidget {
  const _RowExtentProbe({required this.onExtent, required this.child});

  final ValueChanged<double> onExtent;
  final Widget child;

  @override
  State<_RowExtentProbe> createState() => _RowExtentProbeState();
}

class _RowExtentProbeState extends State<_RowExtentProbe> {
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) widget.onExtent(box.size.height);
    });
    return widget.child;
  }
}
