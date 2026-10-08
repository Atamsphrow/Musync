/// Playback settings, exposed synchronously.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/audio/mp3_gapless.dart';
import 'package:musync/features/player/providers/player_provider.dart';
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

  /// Règle le décalage d'affichage des paroles (assistant IA).
  /// Borné à ±1000 ms comme le fichier : au-delà, les lignes dépassent
  /// leurs voisines et c'est forcément une erreur.
  Future<void> setOffset(Duration offset) async {
    final ms = offset.inMilliseconds
        .clamp(-PlaybackSettings.maxOffsetMs, PlaybackSettings.maxOffsetMs);
    final next = state.copyWith(lyricsOffsetMs: ms);
    if (next == state) return;
    state = next;
    try {
      await ref.read(playbackSettingsStoreProvider).save(next);
    } catch (_) {
      // Le changement est déjà vrai dans l'app ; le perdre ne coûte que le
      // prochain lancement. Même politique que les autres réglages.
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
