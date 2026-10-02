import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/providers/playback_settings_provider.dart';

/// Lyrics for the current song, tagged with the song they were read for.
///
/// The tag is what keeps the floating bubble honest at track changes: while
/// the next track's lyrics load, this provider still exposes the previous
/// track's value, and only the tag tells the two apart. Sampling the old
/// song's lines with the new position is what pinned the bubble on the old
/// song's last line forever.
/// Modification time of the current song's file, polled while the song is
/// current. An external tag edit (Musicolet, a file manager, a download
/// finishing) changes the mtime, and only a real change is yielded — never
/// the initial read, which would rebuild the lyrics provider in the middle
/// of its own first load and orphan the future its callers are awaiting.
///
/// Deliberately NOT autoDispose: an autoDispose stream watched from a
/// FutureProvider can dispose and recreate itself across the FutureProvider's
/// rebuild, re-yielding and rebuilding in a loop. One stat every two seconds
/// for the app's lifetime is negligible; the container's disposal still stops
/// it in tests.
final _currentSongMtimeProvider = StreamProvider<int>((ref) async* {
  final song = ref.watch(currentSongProvider);
  if (song == null) return;

  Future<int> mtime() async {
    try {
      return (await File(song.filePath).lastModified()).millisecondsSinceEpoch;
    } catch (_) {
      return -1;
    }
  }

  var last = await mtime();
  await for (final _ in Stream.periodic(const Duration(seconds: 2))) {
    final current = await mtime();
    if (current != last) {
      last = current;
      yield current;
    }
  }
});

final currentLyricsProvider =
    FutureProvider<({Song? song, SyncedLyrics? synced, UnsyncedLyrics? unsynced})>((
      ref,
    ) async {
      final currentSong = ref.watch(currentSongProvider);
      if (currentSong == null) {
        return (song: null, synced: null, unsynced: null);
      }
      // Follow the file, not the cache: the mtime stream above rebuilds this
      // provider whenever another app rewrites the tag, so what is shown is
      // always what is on disk right now.
      ref.watch(_currentSongMtimeProvider);
      // Frame-walking: the tag's artwork is skipped, not loaded.
      final lyrics = await Id3Reader.readLyricsFrames(currentSong.filePath);
      return (
        song: currentSong,
        synced: lyrics.synced,
        unsynced: lyrics.unsynced,
      );
    });

/// Re-reads the current song's lyrics from disk, unconditionally. Called
/// when the app returns to the foreground, which is when a tag edit made in
/// another app (Musicolet, …) becomes visible.
///
/// Deliberately NOT gated on the file's mtime: some tag editors preserve the
/// modification time when writing, so "changed on disk" is not the same as
/// "mtime changed". A local ID3 read costs milliseconds; a stale lyric costs
/// the user's trust. The 2-second mtime poll in [_currentSongMtimeProvider]
/// stays as the fast path while the app is foregrounded.
void refreshLyricsOnForeground(WidgetRef ref) {
  if (ref.read(currentSongProvider) == null) return;
  ref.invalidate(currentLyricsProvider);
}

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
  // Song-tagged like the bubble: while the next track's lyrics load, the
  // provider above still holds the previous track's, and ticking the old
  // lines with the new position would light the wrong line.
  final song = ref.watch(currentSongProvider);
  final pair = ref.watch(currentLyricsProvider).valueOrNull;
  final synced = pair?.song?.id == song?.id ? pair?.synced : null;
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
