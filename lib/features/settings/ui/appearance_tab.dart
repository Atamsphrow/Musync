/// The "Apparence" settings tab: lyrics font size, alignment, style, italic
/// and colors — for the now-playing screen and, separately, the floating
/// bubble. The bubble's own settings live here too now.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/bubble/ui/lyrics_bubble_button.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';
import 'package:musync/features/settings/providers/lyrics_appearance_provider.dart';

class AppearanceTab extends ConsumerWidget {
  const AppearanceTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(lyricsAppearanceProvider);
    final notifier = ref.read(lyricsAppearanceProvider.notifier);
    final textTheme = Theme.of(context).textTheme;

    Future<void> update(LyricsAppearance next) => notifier.update(next);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: [
        Text('Taille du texte', style: textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<LyricsFontSize>(
          segments: const [
            ButtonSegment(
              value: LyricsFontSize.small,
              icon: Text('T', style: TextStyle(fontSize: 14)),
            ),
            ButtonSegment(
              value: LyricsFontSize.medium,
              icon: Text('T', style: TextStyle(fontSize: 18)),
            ),
            ButtonSegment(
              value: LyricsFontSize.large,
              icon: Text('T', style: TextStyle(fontSize: 22)),
            ),
          ],
          selected: {appearance.fontSize},
          onSelectionChanged: (s) => update(appearance.copyWith(fontSize: s.first)),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 20),
        Text('Alignement', style: textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<LyricsTextAlign>(
          segments: const [
            ButtonSegment(
              value: LyricsTextAlign.left,
              icon: Icon(Icons.format_align_left),
            ),
            ButtonSegment(
              value: LyricsTextAlign.center,
              icon: Icon(Icons.format_align_center),
            ),
            ButtonSegment(
              value: LyricsTextAlign.right,
              icon: Icon(Icons.format_align_right),
            ),
          ],
          selected: {appearance.textAlign},
          onSelectionChanged: (s) =>
              update(appearance.copyWith(textAlign: s.first)),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 20),
        Text('Style de police', style: textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<LyricsFontStyle>(
          segments: const [
            ButtonSegment(
              value: LyricsFontStyle.normal,
              icon: Text('Abc', style: TextStyle(fontSize: 18)),
            ),
            ButtonSegment(
              value: LyricsFontStyle.stylized,
              icon: Text(
                'Abc',
                style: TextStyle(
                  fontSize: 18,
                  fontStyle: FontStyle.italic,
                  fontFamily: 'serif',
                ),
              ),
            ),
          ],
          selected: {appearance.fontStyle},
          onSelectionChanged: (s) =>
              update(appearance.copyWith(fontStyle: s.first)),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          value: appearance.italic,
          onChanged: (v) => update(appearance.copyWith(italic: v)),
          title: const Text('Italique'),
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(height: 32),
        Text('Couleur des paroles', style: textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Écran Lecture en cours',
          style: textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SegmentedButton<LyricsColorMode>(
          segments: const [
            ButtonSegment(
              value: LyricsColorMode.white,
              label: Text('Blanc'),
            ),
            ButtonSegment(
              value: LyricsColorMode.materialYou,
              label: Text('Material You'),
            ),
          ],
          selected: {appearance.colorMode},
          onSelectionChanged: (s) =>
              update(appearance.copyWith(colorMode: s.first)),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 16),
        Text(
          'Bulle flottante (choix séparé)',
          style: textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SegmentedButton<LyricsColorMode>(
          segments: const [
            ButtonSegment(
              value: LyricsColorMode.white,
              label: Text('Blanc'),
            ),
            ButtonSegment(
              value: LyricsColorMode.materialYou,
              label: Text('Material You'),
            ),
          ],
          selected: {appearance.bubbleColorMode},
          onSelectionChanged: (s) =>
              update(appearance.copyWith(bubbleColorMode: s.first)),
          showSelectedIcon: false,
        ),
        const Divider(height: 32),
        const _BubbleSetting(),
      ],
    );
  }
}

/// How the floating lyrics bubble looks. Starting it is not here on purpose:
/// that stays a deliberate tap on the now-playing screen.
class _BubbleSetting extends StatelessWidget {
  const _BubbleSetting();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Bulle de paroles flottante',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        const BubbleLinesSelector(),
      ],
    );
  }
}
