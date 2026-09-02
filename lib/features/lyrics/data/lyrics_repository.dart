import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/media_store.dart';
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
        } catch (error, stack) {
          // Anything at all, not just the exception the sources mean to throw.
          //
          // Catching only `LyricsSourceException` left the promise above
          // unkept: a server answering with a number where a string was
          // expected raises a TypeError from the JSON mapping, `Future.wait`
          // hands it straight out, and one misbehaving source took down a
          // search the others could have answered. Whatever it was, it is that
          // source's failure and not the search's.
          DebugLog.instance.error(
            'Recherche',
            'Échec inattendu de la source ${source.name}',
            error: error,
            stackTrace: stack,
          );
          return LyricsSourceException(
            source.name,
            '${source.name} a renvoyé une réponse inattendue.',
            error,
          );
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

    // Stable: `List.sort` is not, and two sources returning equally confident
    // hits would otherwise swap places between one search and the next for no
    // reason the user could see.
    final ranked =
        List<({int index, LyricsSearchResult result})>.generate(
          results.length,
          (i) => (index: i, result: results[i]),
          growable: false,
        )..sort((a, b) {
          final byConfidence = b.result.confidence.compareTo(
            a.result.confidence,
          );
          return byConfidence != 0 ? byConfidence : a.index.compareTo(b.index);
        });
    return [for (final entry in ranked) entry.result];
  }

  /// Throws [Id3WriteException] when the file can't be written.
  ///
  /// The rescan afterwards is not optional housekeeping: the write swaps the
  /// file for a new inode, and until MediaStore is told, every player that
  /// reads the library through it still points at the old one. See
  /// [MediaStore.rescan]. It deliberately cannot fail the save — the lyrics are
  /// already on disk by then, and a stale index is the lesser problem.
  Future<void> embedLyrics(
    String filePath, {
    SyncedLyrics? synced,
    UnsyncedLyrics? unsynced,
  }) async {
    await Id3Writer.writeLyrics(filePath, synced: synced, unsynced: unsynced);
    await MediaStore.rescan(filePath);
  }

  Future<LyricsPair> readLyrics(String filePath) =>
      Id3Reader.readLyrics(filePath);
}
