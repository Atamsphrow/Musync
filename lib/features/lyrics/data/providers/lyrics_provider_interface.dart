import 'package:flutter/foundation.dart';
import 'package:musync/core/id3/models/lyrics.dart';

/// A place lyrics can be fetched from.
///
/// Adding a source in V2 means implementing this and appending it to the list
/// in `LyricsRepository` — nothing else in the app has to change. Results from
/// every source are merged and ranked by [LyricsSearchResult.confidence], so a
/// new source has to score its matches on the same scale to slot in.
abstract class LyricsSource {
  /// Shown next to each result so the user can tell where it came from.
  String get name;

  /// Throws [LyricsSourceException] when the source can't be reached or
  /// answers with something unusable. Returning an empty list means the source
  /// was reached and genuinely knows nothing — the two are not the same, and
  /// the UI says so.
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
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

  const LyricsSearchResult({
    required this.source,
    required this.title,
    required this.artist,
    this.album,
    this.syncedLyrics,
    this.unsyncedLyrics,
    required this.confidence,
  });

  bool get hasSyncedLyrics => syncedLyrics != null && syncedLyrics!.isNotEmpty;
  bool get hasUnsyncedLyrics =>
      unsyncedLyrics != null && unsyncedLyrics!.isNotEmpty;

  /// Nothing worth embedding — filtered out before the list is shown.
  bool get isEmpty => !hasSyncedLyrics && !hasUnsyncedLyrics;
}
