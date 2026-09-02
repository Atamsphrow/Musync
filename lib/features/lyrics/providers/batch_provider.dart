/// Fetching lyrics for many tracks at once, with a look before anything is
/// written.
///
/// A library of several hundred tracks makes the one-at-a-time flow untenable:
/// the "Sans paroles" tab is a to-do list with no way to work through it. But a
/// search is a *guess* — LRCLIB matches on title and artist, and tags are wrong
/// often enough that this app exists — so writing three hundred guesses
/// unattended is exactly the wrong answer.
///
/// Hence two phases. Search everything, then show what was found and let the
/// user decide. Confident matches arrive already ticked; doubtful ones do not.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';
import 'package:musync/core/utils/text_search.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';

enum BatchPhase { idle, searching, review, writing, done }

/// One track and what the search turned up for it.
class BatchCandidate {
  final Song song;

  /// Best match, or null when nothing was found.
  final LyricsSearchResult? match;

  /// Why the search failed, when it did. Distinct from "found nothing".
  final String? error;

  final bool selected;

  /// The query that produced this result, or that came back empty.
  ///
  /// Kept so a miss can say why it missed. T12 reports 56 matches out of 1876
  /// and asks which of several hypotheses is at fault; the answer is usually
  /// visible the moment you can see that the app searched for `09` by
  /// `<unknown>`. A count of failures cannot show that. This can.
  final String queriedTitle;
  final String queriedArtist;

  /// True when the match came from the file name rather than from the tags.
  final bool viaFilename;

  const BatchCandidate({
    required this.song,
    this.match,
    this.error,
    this.selected = false,
    this.queriedTitle = '',
    this.queriedArtist = '',
    this.viaFilename = false,
  });

  bool get hasMatch => match != null;

  /// Above the bar that gets a box ticked on arrival.
  bool get isConfident =>
      match != null && match!.confidence >= autoSelectConfidence;

  /// Ticked on arrival.
  ///
  /// The threshold is deliberately high. Everything below it is still offered —
  /// it is often right — but it is offered *unticked*, because the cost of a
  /// wrong tag written unattended across a library is far higher than the cost
  /// of ticking a few boxes by hand.
  static const double autoSelectConfidence = 0.8;

  BatchCandidate copyWith({
    LyricsSearchResult? match,
    String? error,
    bool? selected,
    String? queriedTitle,
    String? queriedArtist,
    bool? viaFilename,
  }) => BatchCandidate(
    song: song,
    match: match ?? this.match,
    error: error ?? this.error,
    selected: selected ?? this.selected,
    queriedTitle: queriedTitle ?? this.queriedTitle,
    queriedArtist: queriedArtist ?? this.queriedArtist,
    viaFilename: viaFilename ?? this.viaFilename,
  );
}

class BatchState {
  final BatchPhase phase;
  final List<BatchCandidate> candidates;

  /// How many tracks have been looked up so far, for the progress bar.
  final int done;
  final int total;

  /// Written successfully during the writing phase.
  final int written;

  const BatchState({
    this.phase = BatchPhase.idle,
    this.candidates = const [],
    this.done = 0,
    this.total = 0,
    this.written = 0,
  });

  BatchState copyWith({
    BatchPhase? phase,
    List<BatchCandidate>? candidates,
    int? done,
    int? total,
    int? written,
  }) => BatchState(
    phase: phase ?? this.phase,
    candidates: candidates ?? this.candidates,
    done: done ?? this.done,
    total: total ?? this.total,
    written: written ?? this.written,
  );

  Iterable<BatchCandidate> get found => candidates.where((c) => c.hasMatch);
  Iterable<BatchCandidate> get selected => candidates.where((c) => c.selected);
  int get missing => candidates.where((c) => !c.hasMatch).length;
}

final batchProvider = NotifierProvider<BatchNotifier, BatchState>(
  BatchNotifier.new,
);

class BatchNotifier extends Notifier<BatchState> {
  /// Set by [cancel], read between batches. A search already in flight is
  /// allowed to finish rather than being torn down — it costs a second and
  /// leaves the sources' rate limits alone.
  bool _cancelled = false;

  /// Which run of [start] owns the state.
  ///
  /// Incremented by every [start] and every [reset]. A run that finds the
  /// counter moved on stops writing to state at once, which is what keeps an
  /// abandoned search from stamping its results over a newer one.
  int _generation = 0;

  /// Tracks written in this session, by path.
  ///
  /// By path and not by index: an index into a list that gets rebuilt is exactly
  /// what made an interrupted batch redo hundreds of files it had already done.
  /// A path still names the same track after the list is filtered, re-sorted, or
  /// scanned again.
  final Set<String> _writtenPaths = <String>{};

  @override
  BatchState build() => const BatchState();

  /// Whether work is in flight. Re-entering the screen must show this, not
  /// restart it.
  bool get isBusy =>
      state.phase == BatchPhase.searching || state.phase == BatchPhase.writing;

  /// Whether [songs] is the batch already in hand.
  ///
  /// Reopening the screen on the same selection has to find the review it left,
  /// so the same list is recognised rather than re-searched. Order is not part
  /// of the comparison — the library's sort order can change underneath.
  bool holdsSameBatch(List<Song> songs) {
    if (state.candidates.length != songs.length) return false;
    final have = state.candidates.map((c) => c.song.filePath).toSet();
    return songs.every((s) => have.contains(s.filePath));
  }

  /// Whether this track has already been written in this session.
  bool wasWritten(String filePath) => _writtenPaths.contains(filePath);

  /// The tracks of this batch that were written, in the batch's own order.
  ///
  /// A count answered "how many" and left "which ones" unanswerable — the only
  /// way to find out was to open Paramètres › Historique and read a list of
  /// every write the app has ever made, this batch's or not.
  List<Song> get written => [
    for (final candidate in state.candidates)
      if (_writtenPaths.contains(candidate.song.filePath)) candidate.song,
  ];

  /// How many lookups are in flight at once.
  ///
  /// Small on purpose. LRCLIB is a free community service and this can be
  /// eighteen hundred requests; opening thirty connections at it would be rude
  /// and would earn a rate limit that helps nobody.
  static const int _concurrency = 4;

  /// Minimum spacing between the *starts* of two lookups.
  ///
  /// This, and not the worker count, is what bounds the load: four workers with
  /// a 150 ms floor can never exceed about seven lookups a second however fast
  /// the network is. The previous shape — batches of three with a fixed pause
  /// after each — bounded it too, but by stalling: a batch took as long as its
  /// slowest member, so two fast lookups sat idle waiting for a slow one, and
  /// then everything waited another quarter second. Same politeness, roughly
  /// half the wall-clock.
  static const Duration _minSpacing = Duration(milliseconds: 150);

  /// When the next lookup may start. Shared by the workers, which is what makes
  /// the ceiling global rather than per worker.
  DateTime _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _awaitSlot() async {
    final now = DateTime.now();
    final slot = _nextSlot.isAfter(now) ? _nextSlot : now;
    _nextSlot = slot.add(_minSpacing);
    final wait = slot.difference(now);
    if (wait > Duration.zero) await Future.delayed(wait);
  }

  /// Searches every track in [songs].
  ///
  /// Does nothing if a search is already running, or if this is the batch
  /// already on screen — both are the same call, made when the screen is
  /// reopened, and neither should throw away work.
  Future<void> start(List<Song> songs) async {
    if (songs.isEmpty) return;
    if (isBusy) return;
    if (state.phase != BatchPhase.idle && holdsSameBatch(songs)) return;

    _cancelled = false;
    _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);
    final run = ++_generation;

    // The run's own list, fixed at this length for its whole lifetime.
    //
    // This used to read `state.candidates` back on every iteration and write
    // into it by index — which crashed with `RangeError (length): Valid value
    // range is empty` whenever the state was replaced mid-flight, because the
    // screen's `dispose` reset it to an empty list. Owning the list locally
    // makes that class of fault impossible rather than merely guarded against:
    // the index can no longer outrun the thing it indexes.
    final candidates = [for (final song in songs) BatchCandidate(song: song)];

    state = BatchState(
      phase: BatchPhase.searching,
      candidates: List.of(candidates),
      total: songs.length,
    );

    final repository = ref.read(lyricsRepositoryProvider);

    // A shared cursor rather than a slice per worker: tracks differ in how long
    // they take, and handing each worker a fixed third of the list would leave
    // two of them finished while the third still had a hundred to go.
    var next = 0;
    var completed = 0;

    Future<void> work() async {
      while (true) {
        if (_cancelled || run != _generation) return;
        final index = next++;
        if (index >= songs.length) return;

        await _awaitSlot();
        if (_cancelled || run != _generation) return;

        final result = await _searchOne(repository, songs[index]);

        // Checked again on the far side of the await: a reset can land while a
        // lookup is in flight, and a stale run must not publish anything.
        if (run != _generation) return;

        candidates[index] = result;
        completed++;
        state = state.copyWith(
          candidates: List.of(candidates),
          done: completed,
        );
      }
    }

    await Future.wait([for (var i = 0; i < _concurrency; i++) work()]);

    if (run != _generation) return;
    state = state.copyWith(phase: BatchPhase.review);
  }

  Future<BatchCandidate> _searchOne(
    LyricsRepository repository,
    Song song,
  ) async {
    // A placeholder is not a search term.
    //
    // An untagged file reaches here as artist "Artiste inconnu" and album
    // "Album inconnu" — display strings the scanner substitutes so the library
    // list reads properly. Sent to LRCLIB they are a French phrase nobody
    // recorded, so the query cannot match and the album term actively drags the
    // confidence score down on the ones that otherwise would. On a library
    // built from downloads that is a large share of T12's 1820 misses.
    final taggedArtist = MusicScanner.isUnknown(song.artist) ? '' : song.artist;
    final taggedAlbum = MusicScanner.isUnknown(song.album) ? null : song.album;

    try {
      final tagged = await repository.searchAll(
        title: song.title,
        artist: taggedArtist,
        album: taggedAlbum,
        durationMs: song.duration,
      );
      if (tagged.isNotEmpty) {
        return _fromResults(
          song,
          tagged,
          title: song.title,
          artist: taggedArtist,
        );
      }

      // Nothing on the tags. Try what the file name says before giving up.
      //
      // This is the other half of T12, and probably the larger half: a library
      // built from downloads is full of tracks tagged `09` by `<unknown>`, and
      // the app already knows how to read `Mr SAYDA - MBA MARINA (Official
      // Video 2017).mp3`. That reader was wired into the one-song search screen
      // only, so the batch — the one place looking at eighteen hundred files —
      // was the one place searching the tags and stopping there.
      //
      // Costs one extra lookup, and only on a miss.
      final guess = FilenameParser.parse(song.filePath);
      if (_worthRetrying(guess, song.title, taggedArtist)) {
        await _awaitSlot();
        final guessed = await repository.searchAll(
          title: guess.title,
          artist: guess.artist,
          durationMs: song.duration,
        );
        if (guessed.isNotEmpty) {
          return _fromResults(
            song,
            guessed,
            title: guess.title,
            artist: guess.artist,
            viaFilename: true,
          );
        }
      }

      // Both queries came back empty. Record the last one tried: a miss is only
      // diagnosable if you can see what was asked.
      return BatchCandidate(
        song: song,
        queriedTitle: guess.title.isEmpty ? song.title : guess.title,
        queriedArtist: guess.artist.isEmpty ? taggedArtist : guess.artist,
      );
    } on LyricsSourceException catch (e) {
      return BatchCandidate(song: song, error: e.message);
    } catch (e) {
      DebugLog.instance.warning('Lot', 'Échec sur ${song.title} : $e');
      return BatchCandidate(song: song, error: '$e');
    }
  }

  /// Whether the file name is worth a second query.
  ///
  /// Folded, so an accent or a capital does not make two identical queries look
  /// different and buy a round trip for nothing. Two cases are refused:
  ///
  /// - the guess asks exactly what the tags already asked;
  /// - the guess repeats the title but has no artist, while the tags had one.
  ///   That is a strictly poorer question, and asking it costs a request to
  ///   get a worse answer.
  static bool _worthRetrying(
    FilenameGuess guess,
    String taggedTitle,
    String taggedArtist,
  ) {
    if (guess.title.trim().isEmpty) return false;

    final sameTitle = foldForSearch(guess.title) == foldForSearch(taggedTitle);
    final sameArtist =
        foldForSearch(guess.artist) == foldForSearch(taggedArtist);
    if (sameTitle && sameArtist) return false;
    if (sameTitle && guess.artist.trim().isEmpty && taggedArtist.isNotEmpty) {
      return false;
    }
    return true;
  }

  BatchCandidate _fromResults(
    Song song,
    List<LyricsSearchResult> results, {
    required String title,
    required String artist,
    bool viaFilename = false,
  }) {
    // Already ranked best-first by the repository.
    final best = results.first;
    return BatchCandidate(
      song: song,
      match: best,
      selected: best.confidence >= BatchCandidate.autoSelectConfidence,
      queriedTitle: title,
      queriedArtist: artist,
      viaFilename: viaFilename,
    );
  }

  /// Stops after the batch in flight. The results already gathered are kept —
  /// stopping early should still leave something worth reviewing.
  void cancel() {
    _cancelled = true;
    if (state.phase == BatchPhase.searching) {
      state = state.copyWith(phase: BatchPhase.review);
    }
  }

  void toggle(int index) {
    if (index < 0 || index >= state.candidates.length) return;
    final candidate = state.candidates[index];
    if (!candidate.hasMatch) return;

    final updated = [...state.candidates];
    updated[index] = candidate.copyWith(selected: !candidate.selected);
    state = state.copyWith(candidates: updated);
  }

  void selectAll({required bool selected}) {
    state = state.copyWith(
      candidates: [
        for (final c in state.candidates)
          c.hasMatch ? c.copyWith(selected: selected) : c,
      ],
    );
  }

  /// Back to what arrived ticked — the confident matches, and only those.
  void selectConfidentOnly() {
    state = state.copyWith(
      candidates: [
        for (final c in state.candidates)
          c.copyWith(
            selected:
                c.hasMatch &&
                c.match!.confidence >= BatchCandidate.autoSelectConfidence,
          ),
      ],
    );
  }

  void beginWriting() => state = state.copyWith(phase: BatchPhase.writing);

  /// Records a track as written, and refuses to count it twice.
  ///
  /// The count is derived from the set rather than incremented, so resuming an
  /// interrupted write cannot inflate it.
  void recordWritten(String filePath) {
    _writtenPaths.add(filePath);
    state = state.copyWith(written: _countWrittenHere());
  }

  int _countWrittenHere() => state.candidates
      .where((c) => _writtenPaths.contains(c.song.filePath))
      .length;

  void finish() => state = state.copyWith(phase: BatchPhase.done);

  /// Clears everything and abandons any run in flight.
  ///
  /// Only ever called from an explicit user action. It used to be called from
  /// the screen's `dispose`, which meant the back arrow silently killed a scan
  /// the user had not asked to stop — and left the running loop writing into the
  /// list this had just emptied.
  void reset() {
    _cancelled = true;
    _generation++;
    _writtenPaths.clear();
    state = const BatchState();
  }
}
