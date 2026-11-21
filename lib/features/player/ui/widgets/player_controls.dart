import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musync/features/player/providers/player_provider.dart';

class PlayerControls extends ConsumerWidget {
  const PlayerControls({super.key});

  /// Runs a player action, logging instead of dropping its error: these
  /// buttons used to fire the Future and forget it, so a just_audio
  /// failure (no source, source in error) became an unhandled async
  /// error and the tap silently did nothing.
  ///
  /// Public so every other transport control (mini player, seek bar) gets
  /// the same guard instead of an unhandled async error.
  static Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      // Logged, not dropped: the tap did nothing, and silence would leave
      // no trace of why. `debugPrint`, not the journal: this widget must
      // not depend on the journal service.
      debugPrint('Lecteur: action du lecteur impossible: $error');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final playerService = ref.watch(audioPlayerServiceProvider);

    // These drive the shuffle/repeat button states, so the widget has to
    // rebuild when they change — not just when the player state does.
    // Loading/error is handled explicitly: `.value ?? default` used to
    // paint "off" while the stream had no value yet, or had failed.
    // Until a stream has delivered, its button is disabled rather than
    // showing a state that is not real.
    final shuffleAsync = ref.watch(shuffleModeProvider);
    final loopAsync = ref.watch(loopModeProvider);
    final isShuffle = shuffleAsync.valueOrNull ?? false;
    final loopMode = loopAsync.valueOrNull ?? LoopMode.off;
    final shuffleReady = shuffleAsync is AsyncData<bool>;
    final loopReady = loopAsync is AsyncData<LoopMode>;

    final isPlaying = ref.watch(isPlayingProvider);

    final repeatIcon = loopMode == LoopMode.one
        ? Icons.repeat_one
        : Icons.repeat;
    final repeatColor = loopMode == LoopMode.off
        ? scheme.onSurfaceVariant
        : scheme.primary;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: Icon(
            Icons.shuffle,
            color: isShuffle ? scheme.primary : scheme.onSurfaceVariant,
          ),
          tooltip: 'Lecture aléatoire',
          onPressed: shuffleReady
              ? () => run(playerService.toggleShuffle)
              : null,
        ),
        IconButton(
          iconSize: 36,
          icon: Icon(Icons.skip_previous, color: scheme.onSurface),
          tooltip: 'Précédent',
          onPressed: () => run(playerService.previous),
        ),
        // The one filled, high-emphasis control on the screen.
        Material(
          color: scheme.primaryContainer,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            label: isPlaying ? 'Pause' : 'Lecture',
            button: true,
            child: InkWell(
              onTap: () {
                HapticFeedback.lightImpact();
                unawaited(
                  run(isPlaying ? playerService.pause : playerService.play),
                );
              },
              child: SizedBox(
                width: 68,
                height: 68,
                child: BufferingRing(
                  diameter: 60,
                  color: scheme.onPrimaryContainer,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      key: ValueKey<bool>(isPlaying),
                      size: 34,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          iconSize: 36,
          icon: Icon(Icons.skip_next, color: scheme.onSurface),
          tooltip: 'Suivant',
          onPressed: () => run(playerService.next),
        ),
        IconButton(
          icon: Icon(repeatIcon, color: repeatColor),
          tooltip: 'Répétition',
          onPressed:
              loopReady ? () => run(playerService.cycleRepeatMode) : null,
        ),
      ],
    );
  }
}

/// Draws a thin spinning ring around [child] while the player is opening or
/// buffering a track, so a tap on Play that takes a moment reads as « on its
/// way » rather than as a tap that did nothing.
///
/// Shown only once the wait has lasted [delay]: a local file usually loads
/// in a few dozen milliseconds, and a ring flashing on every track change
/// would be noise, not feedback. The child stays visible and tappable — the
/// ring never replaces the button.
class BufferingRing extends ConsumerStatefulWidget {
  const BufferingRing({
    super.key,
    required this.child,
    required this.diameter,
    required this.color,
    this.delay = const Duration(milliseconds: 300),
  });

  final Widget child;
  final double diameter;
  final Color color;
  final Duration delay;

  @override
  ConsumerState<BufferingRing> createState() => _BufferingRingState();
}

class _BufferingRingState extends ConsumerState<BufferingRing> {
  Timer? _delayTimer;
  bool _visible = false;

  void _onBuffering(bool buffering) {
    _delayTimer?.cancel();
    _delayTimer = null;
    if (!buffering) {
      if (_visible) setState(() => _visible = false);
      return;
    }
    _delayTimer = Timer(widget.delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual<bool>(
      isBufferingProvider,
      (_, buffering) => _onBuffering(buffering),
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Sized by [child] alone, the ring drawn over it and past its edges:
    // as a plain Stack child the ring grew the Stack from the icon's size
    // to [diameter] when it appeared — inside the mini player's IconButton,
    // which does not clamp its content, the button grew by 8 dp and the
    // title beside it jumped, then jumped back when buffering ended.
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        widget.child,
        if (_visible)
          Positioned.fill(
            child: IgnorePointer(
              child: OverflowBox(
                minWidth: widget.diameter,
                maxWidth: widget.diameter,
                minHeight: widget.diameter,
                maxHeight: widget.diameter,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: widget.color,
                  semanticsLabel: 'Chargement',
                ),
              ),
            ),
          ),
      ],
    );
  }
}
