import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_align.dart';
import 'package:musync/features/lyrics/data/lyrics_mismatch_store.dart';
import 'package:musync/features/lyrics/data/lyrics_source_health.dart';
import 'package:musync/features/lyrics/data/lyrics_word_timings_store.dart';
import 'package:musync/features/lyrics/data/providers/lrclib_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

/// Fans a search out across every configured [LyricsSource] and merges the
/// answers.
///
/// V1 ships one source, but the merging and ranking already assume several —
/// adding one is a single entry in the constructor's default list.
class LyricsRepository {
  final List<LyricsSource> _sources;

  /// Quand il est présent, une écriture de vraies paroles efface la
  /// marque « non correspondant » du morceau. Null dans les tests qui
  /// n'exercent que la recherche.
  final LyricsMismatchStore? _mismatchStore;

  /// Quand il est présent, une écriture de paroles mot à mot y sauve les
  /// mots (offsets relatifs, voir [LyricsWordTimingsStore]). Null dans
  /// les tests qui n'exercent que la recherche.
  final LyricsWordTimingsStore? _wordTimingsStore;

  /// The health of the sources: which are set aside, and which already
  /// said "no lyrics" for a query. One instance per repository by default;
  /// the app injects the shared one so it survives settings rebuilds.
  final LyricsSourceHealth _health;

  LyricsRepository({
    List<LyricsSource>? sources,
    this._mismatchStore,
    this._wordTimingsStore,
    LyricsSourceHealth? health,
  }) : _sources = sources ?? [LrclibSource()],
       _health = health ?? LyricsSourceHealth();

  /// The names of the sources this repository asks, in order. The source
  /// picker sheet lists these: only enabled sources are ever built.
  List<String> get sourceNames =>
      List.unmodifiable(_sources.map((s) => s.name));

  /// The health of the sources, for the picker sheet's states.
  LyricsSourceHealth get health => _health;

  /// Queries every source in parallel and returns their results, best first.
  ///
  /// A source that fails is skipped rather than taking the search down with
  /// it — that is the point of having several. Only when *every* source fails
  /// does this throw, since then there is nothing to show and the user needs to
  /// know why.
  ///
  /// Health: a source set aside by [LyricsSourceHealth] is not asked, and a
  /// source that already said "no lyrics" for this query is not asked again
  /// either — both are skipped silently, and the other sources answer. The
  /// outcome of every source that IS asked feeds the health: an exception
  /// counts towards the three-in-a-row, an empty list is remembered as "no
  /// lyrics", a non-empty list resets the streak.
  Future<List<LyricsSearchResult>> searchAll({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    if (title.trim().isEmpty && artist.trim().isEmpty) return const [];
    if (_sources.isEmpty) return const [];

    final trackKey = lyricsHealthTrackKey(title, artist);
    var setAsideSkipped = 0;

    final outcomes = await Future.wait(
      _sources.map((source) async {
        if (_health.isSetAside(source.name)) {
          setAsideSkipped++;
          return null;
        }
        if (_health.isMissing(trackKey, source.name)) {
          return null;
        }
        try {
          final found = await source.search(
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs,
            filenameGuess: filenameGuess,
          );
          final kept = found.where((r) => !r.isEmpty).toList();
          if (kept.isEmpty) {
            _health.answered(source.name);
            _health.noteMissing(trackKey, source.name);
          } else {
            _health.answered(source.name);
          }
          return kept;
        } on LyricsSourceException catch (e) {
          _health.failed(source.name);
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
          _health.failed(source.name);
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
        results.addAll(outcome);
      }
    }

    // Only when every source failed is there nothing to show and the user
    // needs to know why. If at least one source answered — even with an empty
    // list — the honest outcome is "no results", not the failure of the
    // source that happened to break. (A 403 from LRCLIB on one search must
    // not masquerade as "nothing exists" when lyrics.ovh simply found
    // nothing.)
    if (results.isEmpty && failures.length == _sources.length) {
      throw failures.first;
    }

    // Every source was set aside and none was asked: "no results" would be
    // a lie — nothing was asked. Say so, so the screen can show it instead.
    // (All-memo is different: the sources WERE asked recently and said
    // nothing, so an empty list is the honest answer there.)
    if (results.isEmpty && setAsideSkipped == _sources.length) {
      throw const LyricsSourceException(
        'recherche',
        'Toutes les sources sont momentanément mises de côté. '
        'Réessayez dans quelques minutes, ou forcez une source avec '
        '« Essayer une autre source ».',
      );
    }

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

  /// Queries one source only, by name — the "try another source" bypass.
  ///
  /// A set-aside source is asked anyway (that is the point of the manual
  /// choice: the user may know it is back), and a "no lyrics" memo is
  /// ignored for the same reason. The outcome still feeds the health: a
  /// manual success clears the streak and the cooldown, a manual failure
  /// counts towards the three-in-a-row.
  ///
  /// Throws [LyricsSourceException] when the source is unknown or fails.
  Future<List<LyricsSearchResult>> searchOne({
    required String sourceName,
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    final source = _sources.where((s) => s.name == sourceName).firstOrNull;
    if (source == null) {
      throw LyricsSourceException(
        sourceName,
        'Source inconnue : $sourceName.',
      );
    }
    if (title.trim().isEmpty && artist.trim().isEmpty) return const [];
    final trackKey = lyricsHealthTrackKey(title, artist);
    try {
      final found = await source.search(
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        filenameGuess: filenameGuess,
      );
      final kept = found.where((r) => !r.isEmpty).toList();
      if (kept.isEmpty) {
        _health.answered(source.name);
        _health.noteMissing(trackKey, source.name);
      } else {
        _health.answered(source.name);
      }
      return kept;
    } on LyricsSourceException {
      _health.failed(source.name);
      rethrow;
    } catch (error, stack) {
      DebugLog.instance.error(
        'Recherche',
        'Échec inattendu de la source ${source.name}',
        error: error,
        stackTrace: stack,
      );
      _health.failed(source.name);
      throw LyricsSourceException(
        source.name,
        '${source.name} a renvoyé une réponse inattendue.',
        error,
      );
    }
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

    /// When true, timed [synced] lyrics are re-timed to the file's own
    /// timed lyrics before writing (see [alignLyrics]). Callers set this
    /// when the result comes from another recording (LyricsPlus, lrc.red):
    /// the file's timings are the trusted reference. False everywhere
    /// else — LRCLIB times the file's own cut, the editor is authoritative
    /// about its track, and a plain write has nothing to align.
    bool alignToExisting = false,
  }) async {
    // Aligned before anything is written, so the tag, the mismatch store
    // and the word-timings store all see the same (shifted) lyrics.
    var toWrite = synced;
    if (alignToExisting && synced != null && synced.isNotEmpty) {
      final current = await Id3Reader.readLyricsFrames(filePath);
      final existing = current.synced;
      if (existing != null && existing.isNotEmpty) {
        final aligned = alignLyrics(incoming: synced, reference: existing);
        toWrite = aligned.lyrics;
        DebugLog.instance.info(
          'Paroles',
          aligned.aligned
              ? 'Timings décalés de ${aligned.shiftMs} ms pour $filePath'
              : 'Pas d’alignement fiable pour $filePath : écrits tels quels',
        );
      }
    }
    await Id3Writer.writeLyrics(filePath, synced: toWrite, unsynced: unsynced);
    await MediaStore.rescan(filePath);
    // De vraies paroles viennent d'être enregistrées : le morceau a
    // trouvé ses paroles, la marque « non correspondant » tombe.
    // Jamais sur suppression (les deux nulls) — sinon le bouton
    // « Paroles incorrectes » s'auto-annulerait.
    final hasLyrics =
        (toWrite != null && toWrite.isNotEmpty) ||
        (unsynced != null && unsynced.text.trim().isNotEmpty);
    if (hasLyrics) {
      await _mismatchStore?.unmark(filePath);
      await _mismatchStore?.save();
    }
    // Les mots, quand il y en a : sauvés côté app, jamais dans le fichier
    // (SYLT/USLT/LRC sont au niveau ligne). Une écriture sans mots ne
    // touche pas au store — l'éditeur et le décalage sauvent sans mots,
    // et leurs sauves ne doivent pas tuer le karaoké.
    if (toWrite != null && toWrite.hasWordTimings) {
      await _wordTimingsStore?.saveWords(filePath, toWrite);
      await _wordTimingsStore?.save();
    }
  }

  Future<LyricsPair> readLyrics(String filePath) =>
      Id3Reader.readLyrics(filePath);
}
