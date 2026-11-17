/// « Tout lire » and « Aléatoire » for any list of tracks: a library tab, a
/// search, an artist, an album, the favourites, the history.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';

/// Plays [songs] as the new queue — in order, or shuffled.
///
/// The shuffle mode is set *before* the queue is installed: just_audio
/// shuffles a new source when it is set, starting from the chosen track, so
/// « Aléatoire » gets a fresh order beginning at a random track, and the
/// player's shuffle button tells the truth. « Tout lire » turns shuffle off
/// for the same reason: in order means in order.
///
/// Not awaited past the start: `playSong`'s future follows just_audio's
/// play(), which only completes when playback stops.
Future<void> playSongs(
  WidgetRef ref,
  List<Song> songs, {
  required bool shuffle,
}) async {
  if (songs.isEmpty) return;
  final service = ref.read(audioPlayerServiceProvider);
  try {
    if (service.isShuffleEnabled != shuffle) await service.toggleShuffle();
  } catch (_) {
    // The mode is a nicety; playing the list is the point.
  }
  final index = shuffle ? Random().nextInt(songs.length) : 0;
  unawaited(
    service.playSong(songs[index], queue: songs, index: index).catchError((
      Object _,
    ) {
      appMessengerKey.currentState?.showOnly(
        SnackBar(
          content: Text(
            PlaybackFailure.of(songs[index], canSkip: false).message,
          ),
        ),
      );
    }),
  );
}

/// The two buttons, for list headers: filled-tonal icon buttons, 48 dp.
class PlaySongsButtons extends ConsumerWidget {
  const PlaySongsButtons({super.key, required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = songs.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          icon: const Icon(Icons.play_arrow),
          tooltip: 'Tout lire',
          onPressed: enabled
              ? () => unawaited(playSongs(ref, songs, shuffle: false))
              : null,
        ),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          icon: const Icon(Icons.shuffle),
          tooltip: 'Lecture aléatoire',
          onPressed: enabled
              ? () => unawaited(playSongs(ref, songs, shuffle: true))
              : null,
        ),
      ],
    );
  }
}
