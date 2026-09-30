/// The button on "Lecture en cours" that opens the floating bubble, and the
/// small sheet behind it (on/off, and how many lines to show).
///
/// It is the only way the bubble is ever started.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/bubble/providers/bubble_provider.dart';

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
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => const _BubbleSheet(),
      ),
    );
  }
}

class _BubbleSheet extends ConsumerWidget {
  const _BubbleSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(lyricsBubbleProvider);
    final controller = ref.read(lyricsBubbleProvider.notifier);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Bulle flottante'),
              subtitle: const Text(
                'Affiche la ligne active par-dessus les autres applis.',
              ),
              value: state.active,
              onChanged: (on) async {
                if (!on) {
                  await controller.stop();
                  return;
                }
                final result = await controller.start();
                if (!context.mounted) return;
                switch (result) {
                  case BubbleStart.started:
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
                    ScaffoldMessenger.of(context).showOnly(
                      const SnackBar(
                        content: Text('Impossible d\'ouvrir la bulle.'),
                      ),
                    );
                }
              },
            ),
            const SizedBox(height: 8),
            const BubbleLinesSelector(),
          ],
        ),
      ),
    );
  }
}

/// Choice of 1, 2 or 3 lines, with a line of explanation.
///
/// One widget for the two places it lives — the sheet on the now-playing screen
/// and Settings — so they are the same setting and cannot drift apart.
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
        const SizedBox(height: 4),
        Text(
          'La largeur suit la longueur de la ligne et l\'écran. Seules les '
          'paroles synchronisées sont affichées.',
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
