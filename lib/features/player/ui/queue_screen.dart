import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/providers/named_queue_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';

/// The player's live queue: the ≡ handle moves a track (drag up/down) or
/// removes it (drag right), swipe left to go back to the player, tap one
/// to play it. Opened from the now-playing screen (wired by the
/// coordinator); this widget only owns its own content.
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('File d\u2019attente'),
      ),
      backgroundColor: scheme.surface,
      body: SafeArea(
        top: false,
        child: QueueListBody(
          onSwipeLeft: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}

/// The queue content itself, without the Scaffold: shared by the [QueueScreen]
/// route and the now-playing screen's swipe-in panel.
class QueueListBody extends ConsumerStatefulWidget {
  /// Balayage vers la gauche sur la liste : retour à la lecture en cours.
  /// Fourni par l'hôte (le panneau ferme le panneau, l'écran dépile la
  /// route) — la liste elle-même ne navigue pas.
  final VoidCallback? onSwipeLeft;

  const QueueListBody({super.key, this.onSwipeLeft});

  @override
  ConsumerState<QueueListBody> createState() => _QueueListBodyState();
}

class _QueueListBodyState extends ConsumerState<QueueListBody> {
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

  /// On the current track's row, so it can be scrolled into view exactly.
  final GlobalKey _currentRowKey = GlobalKey();

  /// Whether the « aller au morceau en cours » button shows: the current
  /// track is estimated outside the visible window.
  bool _showLocateButton = false;

  // ── Balayage gauche = retour à la lecture en cours ──
  //
  // Observed through a Listener, outside the gesture arena: the ≡
  // handle's drag listener owns the gestures that start on a row, so a
  // GestureDetector here would never win a leftward drag.
  int? _trackedPointer;
  double _swipeDx = 0;
  double _swipeDy = 0;

  void _onPointerDown(PointerDownEvent event) {
    if (_trackedPointer != null) return;
    _trackedPointer = event.pointer;
    _swipeDx = 0;
    _swipeDy = 0;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _trackedPointer) return;
    _swipeDx += event.delta.dx;
    _swipeDy += event.delta.dy;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _trackedPointer) return;
    _trackedPointer = null;
    final callback = widget.onSwipeLeft;
    if (callback != null &&
        _swipeDx <= -60 &&
        _swipeDx.abs() >= 1.5 * _swipeDy.abs()) {
      callback();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _trackedPointer) _trackedPointer = null;
  }

  // ── Poignée ≡ : glisser à droite = retirer (comme Musicolet) ──
  //
  // La poignée pilote le déplacement vertical via
  // ReorderableDragStartListener ; ce suivi observe le même geste et
  // détecte le glissement horizontal franc vers la droite. Le retrait
  // est différé jusqu'à la fin de l'animation de dépôt du drag —
  // retirer la ligne pendant cette animation casse le drag en cours.
  int? _handlePointer;
  Song? _handleSong;
  double _handleDx = 0;
  double _handleDy = 0;

  void _handleDragStart(PointerDownEvent event, Song song) {
    _handlePointer = event.pointer;
    _handleSong = song;
    _handleDx = 0;
    _handleDy = 0;
  }

  void _handleDragMove(PointerMoveEvent event) {
    if (event.pointer != _handlePointer) return;
    _handleDx += event.delta.dx;
    _handleDy += event.delta.dy;
  }

  void _handleDragEnd(PointerUpEvent event) {
    if (event.pointer != _handlePointer) return;
    _handlePointer = null;
    final song = _handleSong;
    _handleSong = null;
    if (song == null) return;
    if (_handleDx >= 120 && _handleDx.abs() > _handleDy.abs()) {
      Future.delayed(const Duration(milliseconds: 320), () {
        if (mounted) _removeSong(song);
      });
    }
  }

  void _handleDragCancel(PointerCancelEvent event) {
    if (event.pointer == _handlePointer) {
      _handlePointer = null;
      _handleSong = null;
    }
  }

  /// Retire [song] où qu'il soit rendu dans la file — le drag qui a
  /// déclenché le retrait peut aussi l'avoir réordonné entre-temps,
  /// donc jamais d'index capturé à l'avance. `identical` distingue deux
  /// occurrences du même morceau.
  Future<void> _removeSong(Song song) async {
    final queue = ref.read(audioPlayerServiceProvider).queue;
    final index = queue.indexWhere((s) => identical(s, song));
    if (index < 0) return;
    await _remove(index, song);
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateLocateButton);
    // Open on the current track: with a queue of thousands of songs,
    // landing at the top and hunting by hand is not a way in. A jump, not
    // an animation — the distance can be enormous.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToCurrent(animated: false),
    );
  }

  @override
  void dispose() {
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
  /// Two steps: scroll to the row's offset (exact, now that the row height
  /// is measured rather than guessed), then let the row itself settle via
  /// `ensureVisible`. The animated scroll is awaited first: firing the
  /// correction on the next frame raced the animation — the row was not
  /// built yet at the far end, so nothing corrected the landing.
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
    if (!mounted || !_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rowContext = _currentRowKey.currentContext;
      if (!mounted || rowContext == null) return;
      Scrollable.ensureVisible(
        rowContext,
        alignment: 0.5,
        duration: animated ? const Duration(milliseconds: 200) : Duration.zero,
        curve: Curves.easeOutCubic,
      );
      _updateLocateButton();
    });
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
    // Synchronous: ReorderableListView animates the displaced rows from the
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

    // Listener, hors gesture arena : il observe le balayage gauche sans
    // voler leurs gestes aux lignes (la poignée ≡ garde les siens).
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Stack(
        children: [
          queue.isEmpty
              ? Center(
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
          : ReorderableListView.builder(
              // The rows carry their own drag handles; the default ones
              // would double them.
              buildDefaultDragHandles: false,
              scrollController: _scrollController,
              itemCount: queue.length,
              onReorderItem: _reorder,
              itemBuilder: (context, index) {
                final song = queue[index];
                final isCurrent = index == currentIndex;
                // `identityHashCode`: the service keeps the same Song
                // instances across mutations, so this stays stable while
                // remaining unique even if the same track is queued twice
                // (Song equality is by id alone).
                final key =
                    ValueKey('queue_${song.id}_${identityHashCode(song)}');
                return KeyedSubtree(
                  key: key,
                  child: _RowExtentProbe(
                    onExtent: _reportRowExtent,
                    child: Material(
                    key: isCurrent ? _currentRowKey : null,
                    color: isCurrent
                        ? scheme.primaryContainer.withValues(alpha: 0.45)
                        : Colors.transparent,
                    child: ListTile(
                      // La poignée fait tout : glisser en vertical pour
                      // déplacer, glisser à droite pour retirer (suivi
                      // par le Listener, hors arena, comme Musicolet).
                      leading: Listener(
                        onPointerDown: (e) => _handleDragStart(e, song),
                        onPointerMove: _handleDragMove,
                        onPointerUp: _handleDragEnd,
                        onPointerCancel: _handleDragCancel,
                        child: ReorderableDragStartListener(
                          index: index,
                          child: Icon(
                            Icons.drag_handle,
                            color: scheme.onSurfaceVariant,
                          ),
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
                        '${song.artist} • ${song.album}',
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
                  ),
                );
              },
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
