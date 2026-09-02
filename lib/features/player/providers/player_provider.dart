import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/library/data/models/song.dart';

final audioPlayerServiceProvider = Provider<AudioPlayerService>((ref) {
  final service = AudioPlayerService();
  // Not awaited: `onDispose` is synchronous, and the teardown ordering that
  // matters is inside `dispose` itself.
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final currentSongStreamProvider = StreamProvider<Song?>((ref) {
  return ref.watch(audioPlayerServiceProvider).currentSongStream;
});

/// The one answer to "what is playing", for the mini player, the now-playing
/// screen and the library alike.
///
/// It used to recompute off `currentIndexProvider`, which was not enough: two
/// different lists both start at index 0, so switching between the catalogue's
/// tabs moved the audio without ever emitting a new index. The screen went on
/// showing the previous track's title, art and lyrics.
final currentSongProvider = Provider<Song?>((ref) {
  final service = ref.watch(audioPlayerServiceProvider);
  final streamed = ref.watch(currentSongStreamProvider);
  // Falls back to the service's own value so a screen opened mid-playback is
  // filled in immediately, rather than blank until the next track change.
  return streamed.hasValue ? streamed.value : service.currentSong;
});

final playerStateProvider = StreamProvider<PlayerState>((ref) {
  final service = ref.watch(audioPlayerServiceProvider);
  return service.playerStateStream;
});

final positionProvider = StreamProvider<Duration>((ref) {
  final service = ref.watch(audioPlayerServiceProvider);
  return service.positionStream;
});

final durationProvider = StreamProvider<Duration?>((ref) {
  final service = ref.watch(audioPlayerServiceProvider);
  return service.durationStream;
});

final currentIndexProvider = StreamProvider<int?>((ref) {
  final service = ref.watch(audioPlayerServiceProvider);
  return service.currentIndexStream;
});

// Shuffle and repeat live outside PlayerState, so the controls need their own
// subscriptions to rebuild when either is toggled.
final shuffleModeProvider = StreamProvider<bool>((ref) {
  final service = ref.watch(audioPlayerServiceProvider);
  return service.shuffleModeEnabledStream;
});

final loopModeProvider = StreamProvider<LoopMode>((ref) {
  final service = ref.watch(audioPlayerServiceProvider);
  return service.loopModeStream;
});
