/// The button on "Lecture en cours" that toggles the floating bubble directly.
///
/// One tap: on when it is off, off when it is on. No sheet — the only bubble
/// setting (how many lines) lives in Settings / Sources.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/bubble/providers/bubble_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';

class LyricsBubbleButton extends ConsumerWidget {
  const LyricsBubbleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(lyricsBubbleProvider.select((s) => s.active));

    return IconButton(
      isSelected: active,
      icon: const Icon(Icons.picture_in_picture_alt_outlined),
      selectedIcon: const Icon(Icons.picture_in_picture_alt),
      tooltip: 'Bulle de paroles flottante',
      onPressed: () async {
        final controller = ref.read(lyricsBubbleProvider.notifier);
        if (active) {
          await controller.stop();
          return;
        }
        final result = await controller.start();
        if (!context.mounted) return;
        switch (result) {
          case BubbleStart.started:
            // The bubble only shows while playing: if the track is paused or
            // stopped, start it first — otherwise the app would go to the
            // background with nothing to show.
            final playing =
                ref.read(playerStateProvider).valueOrNull?.playing ?? false;
            if (!playing && ref.read(currentSongProvider) != null) {
              // Fire and forget: awaiting play() here once wedged the whole
              // sequence — the track started playing but the app never went
              // to the background, because just_audio's future only resolves
              // once the platform answers. The backgrounding below must never
              // depend on it.
              unawaited(
                ref
                    .read(audioPlayerServiceProvider)
                    .play()
                    .then((_) {}, onError: (_) {}),
              );
            }
            // The bubble stays hidden on this screen (it already shows the
            // synced lyrics): send the whole app to the background so the
            // user sees the bubble floating over their home screen — that is
            // what the button is for. Only when this screen is still on top.
            // Runs unconditionally after the unawaited play() above: a slow
            // or failing play() can never cancel the backgrounding.
            if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
              try {
                await const MethodChannel(
                  'com.atamsphrow.musync/media_store',
                ).invokeMethod('moveTaskToBack');
              } catch (_) {
                // Fallback: just close this screen.
                if (context.mounted) Navigator.of(context).maybePop();
              }
            }
            break;
          case BubbleStart.permissionDenied:
            ScaffoldMessenger.of(context).showOnly(
              const SnackBar(
                content: Text(
                  'Autorise « Afficher par-dessus les autres '
                  'applications » pour Musync.',
                ),
              ),
            );
          case BubbleStart.failed:
            ScaffoldMessenger.of(
              context,
            ).showOnly(const SnackBar(content: Text('Impossible d\'ouvrir la bulle.')));
        }
      },
    );
  }
}

/// Choice of 1, 2 or 3 lines.
///
/// Lives in Settings / Sources — the only bubble setting.
class BubbleLinesSelector extends ConsumerWidget {
  const BubbleLinesSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(lyricsBubbleProvider.select((s) => s.lines));
    final controller = ref.read(lyricsBubbleProvider.notifier);
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Lignes affichées', style: textTheme.labelLarge),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 1, label: Text('1 ligne')),
              ButtonSegment(value: 2, label: Text('2 lignes')),
              ButtonSegment(value: 3, label: Text('3 lignes')),
            ],
            selected: {lines},
            onSelectionChanged: (choice) => controller.setLines(choice.first),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          switch (lines) {
            1 => 'La ligne active seule.',
            2 => 'La ligne active et la suivante.',
            _ => 'La précédente, l\'active et la suivante.',
          },
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
