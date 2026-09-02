import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/providers/playback_settings_provider.dart';

final currentLyricsProvider =
    FutureProvider<({SyncedLyrics? synced, UnsyncedLyrics? unsynced})>((
      ref,
    ) async {
      final currentSong = ref.watch(currentSongProvider);
      if (currentSong == null) {
        return (synced: null, unsynced: null);
      }
      return await Id3Reader.readLyrics(currentSong.filePath);
    });

/// How often the active line is recomputed while a track plays.
///
/// One frame at 60 Hz, and this number is the whole of T22 — and, on the
/// evidence, of T20 as well.
///
/// The line used to be derived from [positionProvider], which is just_audio's
/// `positionStream`: it aims for 800 updates across the track and clamps the
/// period to 16–200 ms, so **anything longer than 160 seconds ticks at exactly
/// 200 ms**. Every line therefore lit up an average of 100 ms late and at worst
/// a full 200 — a constant lag, present from the first line, not growing with
/// the track. That is precisely the offset against Musicolet that T20 attributed
/// to the encoder delay in the Xing/LAME header. It was the polling interval.
///
/// Sampling per frame is cheap enough to make scheduling unnecessary:
/// `AudioPlayerService.position` is a synchronous getter that extrapolates the
/// last platform position with the wall clock (`just_audio.dart:590`), and
/// [SyncedLyrics.getLineAt] is a binary search. So a seek, a pause, a speed
/// change or a track change is accounted for on the very next tick, with no
/// re-arming logic to get wrong — which a scheduled `Future.delayed` per line
/// would have needed for each of those four cases.
const Duration lineRefreshInterval = Duration(milliseconds: 16);

/// Index of the line that should be lit right now, or null when there is none.
///
/// Emits only when the index actually changes, so the sixty samples a second
/// cost one binary search each and rebuild nothing in between.
final currentLineIndexProvider = StreamProvider.autoDispose<int?>((ref) {
  final synced = ref.watch(currentLyricsProvider).valueOrNull?.synced;
  if (synced == null || synced.isEmpty) return Stream.value(null);

  final service = ref.watch(audioPlayerServiceProvider);
  // Watched, not read: dragging the compensation slider has to move the lines
  // as it is dragged, otherwise there is no way to tell when it is right.
  final offset = ref.watch(lyricsOffsetProvider);

  return Stream<int?>.periodic(
    lineRefreshInterval,
    (_) => synced.getLineAt(service.position + offset),
  ).distinct();
});
