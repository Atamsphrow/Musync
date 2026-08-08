import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musync/features/player/providers/player_provider.dart';

class PlayerControls extends ConsumerWidget {
  const PlayerControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final playerService = ref.watch(audioPlayerServiceProvider);
    final playerStateAsync = ref.watch(playerStateProvider);

    // These drive the shuffle/repeat button states, so the widget has to
    // rebuild when they change — not just when the player state does.
    final isShuffle = ref.watch(shuffleModeProvider).value ?? false;
    final loopMode = ref.watch(loopModeProvider).value ?? LoopMode.off;

    final isPlaying = playerStateAsync.value?.playing ?? false;

    final repeatIcon =
        loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat;
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
          onPressed: () => playerService.toggleShuffle(),
        ),
        IconButton(
          iconSize: 36,
          icon: Icon(Icons.skip_previous, color: scheme.onSurface),
          tooltip: 'Précédent',
          onPressed: () => playerService.previous(),
        ),
        // The one filled, high-emphasis control on the screen.
        Material(
          color: scheme.primaryContainer,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () =>
                isPlaying ? playerService.pause() : playerService.play(),
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
        IconButton(
          iconSize: 36,
          icon: Icon(Icons.skip_next, color: scheme.onSurface),
          tooltip: 'Suivant',
          onPressed: () => playerService.next(),
        ),
        IconButton(
          icon: Icon(repeatIcon, color: repeatColor),
          tooltip: 'Répétition',
          onPressed: () => playerService.cycleRepeatMode(),
        ),
      ],
    );
  }
}
