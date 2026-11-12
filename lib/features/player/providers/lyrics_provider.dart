import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/lyrics_word_timings_store.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/lyric_clock.dart';
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
///
/// The stat is the file's mtime + size in one call. The lyrics frames are
/// only re-read when that stat moves (see [lyricsContentHash]): walking the
/// ID3 frames every 2 s cost a full tag read for a value that only changes
/// when the file does.
final _currentSongMtimeProvider = StreamProvider<int>((ref) async* {
  final song = ref.watch(currentSongProvider);
  if (song == null) return;

  /// (mtime, size) of the file, (-1, -1) when it cannot be stat'ed.
  Future<(int, int)> fileStat() async {
    try {
      final stat = await File(song.filePath).stat();
      return (stat.modified.millisecondsSinceEpoch, stat.size);
    } catch (_) {
      return (-1, -1);
    }
  }

  // Content hash of the lyrics frames: some tag editors (Musicolet) preserve
  // the mtime when writing, so mtime alone misses their edits. Hashing the
  // actual lyrics bytes catches every change. Only computed when the file's
  // stat moved (mtime or size) — re-walking the frames on every 2 s tick
  // was the poll's whole cost, for a value that cannot change otherwise.
  Future<int> lyricsHash() async {
    try {
      final pair = await Id3Reader.readLyricsFrames(song.filePath);
      return lyricsContentHash(pair.synced, pair.unsynced);
    } catch (_) {
      return -1;
    }
  }

  // Also watch the sidecar .lrc: Musicolet may write ONLY the sidecar
  // without touching the audio file — then neither mtime nor lyrics hash
  // of the audio changes, and the poll would miss it forever.
  Future<int> sidecarMtime() async {
    final dot = song.filePath.lastIndexOf('.');
    if (dot < 0) return -1;
    final base = song.filePath.substring(0, dot);
    for (final ext in ['.lrc', '.LRC']) {
      try {
        final f = File('$base$ext');
        if (await f.exists()) {
          return (await f.lastModified()).millisecondsSinceEpoch;
        }
      } catch (_) {}
    }
    return -1;
  }

  var (lastMtime, lastSize) = await fileStat();
  var lastHash = await lyricsHash();
  var lastSidecar = await sidecarMtime();
  await for (final _ in Stream.periodic(const Duration(seconds: 2))) {
    // Foreground only: in the background this poll (a file stat, a
    // lyrics-frame read, two sidecar checks every 2 s) buys nothing —
    // refreshLyricsOnForeground re-reads everything on resume anyway.
    if (!ref.read(appForegroundProvider)) continue;
    final (currentMtime, currentSize) = await fileStat();
    // The frames are re-read only when the file moved: same mtime and
    // same size means the lyrics bytes cannot have changed, so the
    // cached hash is reused instead of a fresh frame walk.
    final currentHash = currentMtime != lastMtime || currentSize != lastSize
        ? await lyricsHash()
        : lastHash;
    final currentSidecar = await sidecarMtime();
    if (currentMtime != lastMtime ||
        currentSize != lastSize ||
        currentHash != lastHash ||
        currentSidecar != lastSidecar) {
      lastMtime = currentMtime;
      lastSize = currentSize;
      lastHash = currentHash;
      lastSidecar = currentSidecar;
      yield currentMtime;
    }
  }
});

/// Change-detection hash of a song's lyrics frames — FNV-1a 64-bit over the
/// synced lines (timestamp + text) and the unsynced text.
///
/// Both frames are hashed, never one or the other: an external edit touching
/// only the USLT while a SYLT exists used to leave the hash unchanged and
/// slip past the poll. `String.hashCode` is a 32-bit hash, so collisions
/// were a matter of time; FNV-1a over the raw code units gives 64 bits.
///
/// Change detection only — never a fingerprint, never persisted, never
/// compared across runs (the comparison is always within one execution).
int lyricsContentHash(SyncedLyrics? synced, UnsyncedLyrics? unsynced) {
  var h = 0xcbf29ce484222325;
  void mix(int value) {
    h = (h ^ value) * 0x100000001b3;
  }

  void mixText(String text) {
    for (final unit in text.codeUnits) {
      mix(unit);
    }
    mix(0xFF); // Separator: "ab"+"c" must differ from "a"+"bc".
  }

  if (synced != null) {
    for (final line in synced.lines) {
      mix(line.timestamp?.inMilliseconds ?? -1);
      mixText(line.text);
    }
  }
  mix(0xFE); // Separator between the synced and unsynced parts.
  if (unsynced != null) mixText(unsynced.text);
  return h;
}

final currentLyricsProvider =
    FutureProvider<
      ({Song? song, SyncedLyrics? synced, UnsyncedLyrics? unsynced})
    >((ref) async {
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
      // The words live app-side, never in the file: re-attach them from the
      // store when the lyrics text matches what was saved. A miss returns
      // the lyrics unchanged — line-only, never an error.
      final synced = lyrics.synced == null
          ? null
          : await ref
                .read(lyricsWordTimingsStoreProvider)
                .attachWords(currentSong.filePath, lyrics.synced!);
      return (
        song: currentSong,
        synced: synced,
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

/// The word being sung at [position]: the latest word of the current line
/// whose start has passed — or null before the first word of the line (or
/// before the first line at all).
///
/// A pure function so the rule is unit-testable without a player: the
/// provider below only samples the position.
({int lineIndex, int wordIndex})? currentWordAt(
  SyncedLyrics synced,
  Duration position,
) {
  final lineIndex = synced.getLineAt(position);
  if (lineIndex == null) return null;
  final words = synced.lines[lineIndex].words;
  var wordIndex = -1;
  for (var i = 0; i < words.length; i++) {
    if (words[i].start <= position) wordIndex = i;
  }
  if (wordIndex < 0) return null;
  return (lineIndex: lineIndex, wordIndex: wordIndex);
}

/// The word to light right now, or null when there is none.
///
/// Mirrors [currentLineIndexProvider]: one 16 ms sample, one binary search
/// each while playing, and it emits only when the answer actually changes.
/// A frozen position reuses the last answer instead of re-running the
/// search — same reason as there.
final currentWordIndexProvider = StreamProvider.autoDispose<
  ({int lineIndex, int wordIndex})?
>((ref) {
  // Song-tagged like the line provider: while the next track's lyrics load,
  // the provider above still holds the previous track's, and ticking the
  // old lines with the new position would light the wrong word.
  final song = ref.watch(currentSongProvider);
  final pair = ref.watch(currentLyricsProvider).valueOrNull;
  final synced = pair?.song?.id == song?.id ? pair?.synced : null;
  if (synced == null || synced.isEmpty || !synced.hasWordTimings) {
    return Stream.value(null);
  }

  final service = ref.watch(audioPlayerServiceProvider);
  // Watched, not read: dragging the compensation slider has to move the
  // words as it is dragged, like it moves the lines.
  final offset = ref.watch(lyricsOffsetProvider);

  ({int lineIndex, int wordIndex})? last;
  Duration? lastPosition;
  // One clock per provider, fresh on every rebuild (song change): the raw
  // position never steps back except on a seek, so a jittered anchor
  // cannot un-light a word that is already sung. The compensation offset
  // is added after the clock — dragging the slider must move the words
  // at once, not be absorbed as jitter.
  final clock = LyricClock();
  return Stream<({int lineIndex, int wordIndex})?>.periodic(
    lineRefreshInterval,
    (_) {
      final position = clock.tick(service.position) + offset;
      if (position == lastPosition) return last;
      lastPosition = position;
      return last = currentWordAt(synced, position);
    },
  ).distinct();
});
///
/// Emits only when the index actually changes, so the sixty samples a second
/// cost one binary search each while playing — and none at all while paused:
/// a frozen position reuses the last answer instead of re-running the search
/// (see below). Nothing rebuilds in between either way.
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

  // While paused the position does not move, so re-running the binary search
  // sixty times a second only ever returns the same index. The last position
  // and its answer are kept: a tick whose position has not moved reuses them.
  // A seek while paused still recomputes once, because the position did move.
  Duration? lastPosition;
  int? lastIndex;
  // One clock per provider, fresh on every rebuild (song change): the raw
  // position never steps back except on a seek, so a jittered anchor
  // cannot flick the current line back for a frame. The compensation
  // offset is added after the clock — dragging the slider must move the
  // lines at once, not be absorbed as jitter. The bubble and the
  // mini-player read this provider, so they get the clocked position too.
  final clock = LyricClock();
  return Stream<int?>.periodic(lineRefreshInterval, (_) {
    final position = clock.tick(service.position) + offset;
    if (position == lastPosition) return lastIndex;
    lastPosition = position;
    return lastIndex = synced.getLineAt(position);
  }).distinct();
});
