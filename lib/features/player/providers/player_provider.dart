import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/library/data/models/song.dart';

final audioPlayerServiceProvider = Provider<AudioPlayerService>((ref) {
  final service = AudioPlayerService();
  ref.onDispose(() => service.dispose());
  return service;
});

final currentSongProvider = Provider<Song?>((ref) {
  final service = ref.watch(audioPlayerServiceProvider);
  ref.watch(currentIndexProvider);
  return service.currentSong;
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
