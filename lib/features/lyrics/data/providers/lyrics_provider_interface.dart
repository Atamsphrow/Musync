import 'package:flutter/foundation.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_confidence.dart';

/// A place lyrics can be fetched from.
///
/// Adding a source in V2 means implementing this and appending it to the list
/// in `LyricsRepository` — nothing else in the app has to change. Results from
/// every source are merged and ranked by [LyricsSearchResult.confidence], so a
/// new source has to score its matches on the same scale to slot in.
abstract class LyricsSource {
  /// Shown next to each result so the user can tell where it came from.
  String get name;

  /// True when this source is a last resort: the repository only asks it
  /// when no synced lyrics came back from the others. A plain hit never
  /// blocks it, and a synced hit never needs it. False for every source
  /// except Genius.
  bool get isFallback => false;

  /// Throws [LyricsSourceException] when the source can't be reached or
  /// answers with something unusable. Returning an empty list means the source
  /// was reached and genuinely knows nothing — the two are not the same, and
  /// the UI says so.
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,

    /// What the file name says the track is, when the caller resolved it.
    /// LRCLIB uses it for the filename-agreement bonus and to cap a `/get`
    /// exact hit that contradicts it; a source that cannot use it ignores
    /// it. Null means "not resolved".
    FilenameGuess? filenameGuess,
  });
}

/// A source failed. [message] is written for the user, not for a log.
class LyricsSourceException implements Exception {
  final String source;
  final String message;
  final Object? cause;

  const LyricsSourceException(this.source, this.message, [this.cause]);

  @override
  String toString() => 'LyricsSourceException($source): $message';
}

@immutable
class LyricsSearchResult {
  final String source;
  final String title;
  final String artist;
  final String? album;
  final SyncedLyrics? syncedLyrics;
  final UnsyncedLyrics? unsyncedLyrics;

  /// 0..1, comparable across sources. 1.0 is an exact match on title, artist
  /// and duration; anything below 0.5 is a guess.
  final double confidence;

  /// The source's own id for this track (LRCLIB track id), when the source
  /// has one. Lets the verifier and the provenance store say *which*
  /// recording the lyrics came from, not just what they are called.
  final int? trackId;

  /// The recording's duration in milliseconds, when the source knows it.
  /// The confidence scorer uses it; a source that does not report one
  /// leaves it null and the duration component simply scores 0.
  final int? durationMs;

  const LyricsSearchResult({
    required this.source,
    required this.title,
    required this.artist,
    this.album,
    this.syncedLyrics,
    this.unsyncedLyrics,
    required this.confidence,
    this.trackId,
    this.durationMs,
  });

  bool get hasSyncedLyrics => syncedLyrics != null && syncedLyrics!.isNotEmpty;
  bool get hasUnsyncedLyrics =>
      unsyncedLyrics != null && unsyncedLyrics!.isNotEmpty;

  /// True when the synced lyrics carry word timings (LyricsPlus).
  bool get hasWordTimings =>
      syncedLyrics != null && syncedLyrics!.hasWordTimings;

  /// Nothing worth embedding — filtered out before the list is shown.
  bool get isEmpty => !hasSyncedLyrics && !hasUnsyncedLyrics;
}

/// The one pick every « apply the best hit » path shares — the sweep,
/// the batch, the AI assistant: a synced hit first, in the order the
/// repository ranked them, since synced lyrics are the point of the
/// app; and only when NO hit carries synced lyrics, the best
/// plain-text one. Plain is the fallback, never a dead end — a track
/// LRCLIB only knows in plain form still gets its words.
///
/// Confidence alone does not make this pick: an exact plain-only hit
/// (LRCLIB `/get`, confidence 1.0) would otherwise outrank a synced
/// hit that exists further down the list.
///
/// [results] must already be ranked best-first (the repository's
/// `searchAll` does that). Null when the list is empty.
LyricsSearchResult? bestLyricsMatch(List<LyricsSearchResult> results) =>
    results.where((r) => r.hasSyncedLyrics).firstOrNull ??
    results.where((r) => r.hasUnsyncedLyrics).firstOrNull;

/// The pick every *automatic* path shares — the AI assistant, the
/// background sweep, the batch pre-selection: the same synced-first
/// preference as [bestLyricsMatch], but only among hits at or above
/// [minConfidence] (0.80 by default, the shared threshold).
///
/// A synced hit below the bar never beats a plain hit above it, and
/// when nothing reaches the bar this answers null instead of picking
/// the least-bad guess — that refusal is the whole point of the gate.
/// [results] must already be ranked best-first. Null when the list is
/// empty or nothing reaches the bar.
LyricsSearchResult? bestAutoMatch(
  List<LyricsSearchResult> results, {
  double minConfidence = LyricsConfidence.autoIntegrateConfidence,
}) {
  final above = results.where((r) => r.confidence >= minConfidence);
  return above.where((r) => r.hasSyncedLyrics).firstOrNull ??
      above.where((r) => r.hasUnsyncedLyrics).firstOrNull;
}
