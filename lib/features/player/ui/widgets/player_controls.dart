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
  static Future<void> _run(Future<void> Function() action) async {
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
    final playerStateAsync = ref.watch(playerStateProvider);

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

    final isPlaying = playerStateAsync.value?.playing ?? false;

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
              ? () => _run(playerService.toggleShuffle)
              : null,
        ),
        IconButton(
          iconSize: 36,
          icon: Icon(Icons.skip_previous, color: scheme.onSurface),
          tooltip: 'Précédent',
          onPressed: () => _run(playerService.previous),
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
                  _run(isPlaying ? playerService.pause : playerService.play),
                );
              },
              child: SizedBox(
                width: 68,
                height: 68,
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
        IconButton(
          iconSize: 36,
          icon: Icon(Icons.skip_next, color: scheme.onSurface),
          tooltip: 'Suivant',
          onPressed: () => _run(playerService.next),
        ),
        IconButton(
          icon: Icon(repeatIcon, color: repeatColor),
          tooltip: 'Répétition',
          onPressed:
              loopReady ? () => _run(playerService.cycleRepeatMode) : null,
        ),
      ],
    );
  }
}
