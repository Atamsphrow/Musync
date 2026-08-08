import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/providers/lrclib_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

/// Fans a search out across every configured [LyricsSource] and merges the
/// answers.
///
/// V1 ships one source, but the merging and ranking already assume several —
/// adding one is a single entry in the constructor's default list.
class LyricsRepository {
  final List<LyricsSource> _sources;

  LyricsRepository({List<LyricsSource>? sources})
      : _sources = sources ?? [LrclibSource()];

  /// Queries every source in parallel and returns their results, best first.
  ///
  /// A source that fails is skipped rather than taking the search down with
  /// it — that is the point of having several. Only when *every* source fails
  /// does this throw, since then there is nothing to show and the user needs to
  /// know why.
  Future<List<LyricsSearchResult>> searchAll({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
  }) async {
    if (title.trim().isEmpty && artist.trim().isEmpty) return const [];

    final outcomes = await Future.wait(
      _sources.map((source) async {
        try {
          return await source.search(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs,
          );
        } on LyricsSourceException catch (e) {
          return e;
        }
      }),
    );

    final results = <LyricsSearchResult>[];
    final failures = <LyricsSourceException>[];
    for (final outcome in outcomes) {
      if (outcome is LyricsSourceException) {
        failures.add(outcome);
      } else if (outcome is List<LyricsSearchResult>) {
        results.addAll(outcome.where((r) => !r.isEmpty));
      }
    }

    if (results.isEmpty && failures.isNotEmpty) throw failures.first;

    results.sort((a, b) => b.confidence.compareTo(a.confidence));
    return results;
  }

  /// Throws [Id3WriteException] when the file can't be written.
  Future<void> embedLyrics(
    String filePath, {
    SyncedLyrics? synced,
    UnsyncedLyrics? unsynced,
  }) {
    return Id3Writer.writeLyrics(filePath, synced: synced, unsynced: unsynced);
  }

  Future<LyricsPair> readLyrics(String filePath) => Id3Reader.readLyrics(filePath);
}
