/// Lyrics appearance settings, exposed synchronously.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';

final lyricsAppearanceStoreProvider = Provider<LyricsAppearanceStore>(
  (ref) => const LyricsAppearanceStore(),
);

/// Synchronous like the playback settings: the lyrics view reads this on
/// every build, and an AsyncValue there would mean unwrapping a future for a
/// value that changes when the user taps a segmented button.
final lyricsAppearanceProvider =
    NotifierProvider<LyricsAppearanceNotifier, LyricsAppearance>(
  LyricsAppearanceNotifier.new,
);

class LyricsAppearanceNotifier extends Notifier<LyricsAppearance> {
  @override
  LyricsAppearance build() {
    unawaited(_hydrate());
    return const LyricsAppearance();
  }

  Future<void> _hydrate() async {
    final loaded = await ref.read(lyricsAppearanceStoreProvider).load();
    if (loaded != state) state = loaded;
  }

  Future<void> update(LyricsAppearance next) async {
    state = next;
    try {
      await ref.read(lyricsAppearanceStoreProvider).save(next);
    } catch (_) {
      // The change is already true in the app; losing it only costs the next
      // launch. Same policy as the other settings stores.
    }
  }
}

/// The device's Material You dynamic color scheme (null when the device
/// does not provide one). Updated by the DynamicColorBuilder in main.dart so
/// the floating bubble — which runs in a separate engine with its own theme
/// — can follow it too.
final dynamicColorSchemeProvider = StateProvider<ColorScheme?>((ref) => null);

/// Resolves the active-line color: plain white, or the Material You dynamic
/// primary from the current theme.
Color lyricsActiveColor(
    BuildContext context, LyricsAppearance appearance) {
  if (appearance.colorMode == LyricsColorMode.materialYou) {
    return Theme.of(context).colorScheme.primary;
  }
  return Colors.white;
}

/// Same for the bubble, which has its own independent color choice.
Color bubbleActiveColor(
    BuildContext context, LyricsAppearance appearance) {
  if (appearance.bubbleColorMode == LyricsColorMode.materialYou) {
    return Theme.of(context).colorScheme.primary;
  }
  return Colors.white;
}
