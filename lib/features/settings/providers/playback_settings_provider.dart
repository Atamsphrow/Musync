/// Playback settings, exposed synchronously.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/audio/mp3_gapless.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/settings/data/playback_settings.dart';

final playbackSettingsStoreProvider = Provider<PlaybackSettingsStore>(
  (ref) => const PlaybackSettingsStore(),
);

/// Synchronous on purpose, unlike the other settings in this app.
///
/// The lyrics offset is read on the hot path — once per frame while lyrics are
/// on screen — and an `AsyncValue` there would mean unwrapping a future sixty
/// times a second for a value that changes when the user drags a slider. So the
/// notifier starts at the neutral default and corrects itself a moment later
/// once the file has been read: an offset of zero for the first few frames is
/// exactly what an unconfigured install has anyway.
final playbackSettingsProvider =
    NotifierProvider<PlaybackSettingsNotifier, PlaybackSettings>(
      PlaybackSettingsNotifier.new,
    );

class PlaybackSettingsNotifier extends Notifier<PlaybackSettings> {
  @override
  PlaybackSettings build() {
    unawaited(_hydrate());
    return const PlaybackSettings();
  }

  Future<void> _hydrate() async {
    final loaded = await ref.read(playbackSettingsStoreProvider).load();
    // Only if it says something: assigning the default over the default would
    // notify every listener for nothing.
    if (loaded != state) state = loaded;
  }

  /// Applies the offset immediately and persists it in the background.
  ///
  /// The state moves first so the lines follow the slider as it is dragged;
  /// a failed write costs the setting at the next launch and is logged rather
  /// than thrown, since the change is already true in the app.
  Future<void> setLyricsOffsetMs(int milliseconds) async {
    final clamped = milliseconds.clamp(
      -PlaybackSettings.maxOffsetMs,
      PlaybackSettings.maxOffsetMs,
    );
    if (clamped == state.lyricsOffsetMs) return;

    state = state.copyWith(lyricsOffsetMs: clamped);
    try {
      await ref.read(playbackSettingsStoreProvider).save(state);
    } catch (error, stack) {
      DebugLog.instance.error(
        'Réglages',
        'Enregistrement du décalage des paroles impossible',
        error: error,
        stackTrace: stack,
      );
    }
  }
}

/// Just the offset, so a widget watching it does not rebuild when an unrelated
/// playback setting changes.
final lyricsOffsetProvider = Provider<Duration>(
  (ref) => ref.watch(playbackSettingsProvider).lyricsOffset,
);

/// What the track currently playing declares about its own encoder delay.
///
/// Shown next to the compensation slider, because that is where someone would
/// want it: T20 supposed the constant lag against Musicolet came from the
/// `Xing`/`LAME` gapless fields, and this turns that from a hypothesis into a
/// number read off the user's own files. Null when nothing is playing, or when
/// the file carries no readable MPEG frame.
final currentTrackGaplessProvider = FutureProvider<Mp3GaplessInfo?>((
  ref,
) async {
  final song = ref.watch(currentSongProvider);
  if (song == null) return null;
  return Mp3GaplessReader.read(song.filePath);
});
