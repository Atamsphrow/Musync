// Bulk lyrics fetching.
//
// The logic worth pinning down is what arrives *ticked*: this screen can write
// to hundreds of files, and the difference between a confident match and a
// plausible one is the difference between a useful tool and a library full of
// wrong lyrics.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/providers/batch_provider.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';

/// Answers from a table keyed on the title, so each track in a run can be given
/// its own outcome.
class _FakeSource implements LyricsSource {
  final Map<String, double?> confidenceByTitle;
  final Set<String> failing;

  /// Every title looked up, in order. Proves whether a search actually ran —
  /// checking the resulting state cannot tell a fresh search from a kept one.
  final List<String> queried = [];

  /// The whole of each query, for the ones where the terms are the point.
  final List<({String title, String artist, String? album})> queries = [];

  _FakeSource({this.confidenceByTitle = const {}, this.failing = const {}});

  @override
  String get name => 'fake';

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
  }) async {
    queried.add(title);
    queries.add((title: title, artist: artist, album: album));
    if (failing.contains(title)) {
      throw LyricsSourceException(name, 'source en panne');
    }

    final confidence = confidenceByTitle[title];
    if (confidence == null) return const [];

    return [
      LyricsSearchResult(
        source: name,
        title: 'Trouvé $title',
        artist: artist,
        syncedLyrics: SyncedLyrics([
          const LyricLine(timestamp: Duration.zero, text: 'Une'),
        ]),
        confidence: confidence,
      ),
    ];
  }
}

Song _song(int id, String title) => Song(
  id: id,
  title: title,
  artist: 'Artiste',
  album: 'Album',
  duration: 180000,
  filePath: '/musique/$title.mp3',
);

ProviderContainer _containerWith(_FakeSource source) {
  final container = ProviderContainer(
    overrides: [
      lyricsRepositoryProvider.overrideWithValue(
        LyricsRepository(sources: [source]),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('searching', () {
    test('a confident match arrives already ticked', () async {
      // 0.8 is the bar. Above it, the user should not have to tick anything.
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'A': 0.95}),
      );

      await container.read(batchProvider.notifier).start([_song(1, 'A')]);

      final state = container.read(batchProvider);
      expect(state.phase, BatchPhase.review);
      expect(state.candidates.single.selected, isTrue);
    });

    test('a doubtful match is offered, but unticked', () async {
      // Offered because it is often right; unticked because a wrong tag written
      // unattended across a library costs far more than ticking a box.
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'A': 0.55}),
      );

      await container.read(batchProvider.notifier).start([_song(1, 'A')]);

      final state = container.read(batchProvider);
      expect(state.candidates.single.hasMatch, isTrue);
      expect(state.candidates.single.selected, isFalse);
    });

    test('nothing found is not an error', () async {
      final container = _containerWith(_FakeSource());

      await container.read(batchProvider.notifier).start([_song(1, 'A')]);

      final state = container.read(batchProvider);
      expect(state.candidates.single.hasMatch, isFalse);
      expect(state.candidates.single.error, isNull);
      expect(state.missing, 1);
    });

    test('one source failure does not take the run down', () async {
      // The point of a batch is finishing it. A track that failed is recorded
      // and the rest carry on.
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'B': 0.9}, failing: {'A'}),
      );

      await container.read(batchProvider.notifier).start([
        _song(1, 'A'),
        _song(2, 'B'),
      ]);

      final state = container.read(batchProvider);
      expect(state.candidates.first.error, isNotNull);
      expect(state.candidates.last.selected, isTrue);
      expect(state.phase, BatchPhase.review);
    });

    test('progress reaches the total', () async {
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'A': 0.9, 'B': 0.9, 'C': 0.9}),
      );

      await container.read(batchProvider.notifier).start([
        _song(1, 'A'),
        _song(2, 'B'),
        _song(3, 'C'),
      ]);

      final state = container.read(batchProvider);
      expect(state.done, 3);
      expect(state.total, 3);
      expect(state.found, hasLength(3));
    });

    test('an empty list does nothing at all', () async {
      final container = _containerWith(_FakeSource());
      await container.read(batchProvider.notifier).start([]);
      expect(container.read(batchProvider).phase, BatchPhase.idle);
    });
  });

  group('the selection', () {
    Future<ProviderContainer> reviewing() async {
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'A': 0.95, 'B': 0.5, 'C': null}),
      );
      await container.read(batchProvider.notifier).start([
        _song(1, 'A'),
        _song(2, 'B'),
        _song(3, 'C'),
      ]);
      return container;
    }

    test('starts as the confident ones only', () async {
      final container = await reviewing();
      expect(container.read(batchProvider).selected, hasLength(1));
    });

    test('all and none', () async {
      final container = await reviewing();
      final notifier = container.read(batchProvider.notifier);

      notifier.selectAll(selected: true);
      // Two matches, not three: a track with no result cannot be selected.
      expect(container.read(batchProvider).selected, hasLength(2));

      notifier.selectAll(selected: false);
      expect(container.read(batchProvider).selected, isEmpty);
    });

    test('back to the confident ones', () async {
      final container = await reviewing();
      final notifier = container.read(batchProvider.notifier);

      notifier.selectAll(selected: true);
      notifier.selectConfidentOnly();

      final chosen = container.read(batchProvider).selected;
      expect(chosen, hasLength(1));
      expect(chosen.single.song.title, 'A');
    });

    test('toggling one, and never one without a match', () async {
      final container = await reviewing();
      final notifier = container.read(batchProvider.notifier);

      notifier.toggle(1);
      expect(container.read(batchProvider).candidates[1].selected, isTrue);

      // Index 2 found nothing; there is nothing to write for it.
      notifier.toggle(2);
      expect(container.read(batchProvider).candidates[2].selected, isFalse);
    });

    test('an out-of-range index is ignored rather than fatal', () async {
      final container = await reviewing();
      expect(
        () => container.read(batchProvider.notifier).toggle(99),
        returnsNormally,
      );
    });
  });

  group('stopping', () {
    test('cancel moves to review, keeping what was found', () async {
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'A': 0.9}),
      );
      final notifier = container.read(batchProvider.notifier);

      final run = notifier.start([_song(1, 'A'), _song(2, 'B')]);
      notifier.cancel();
      await run;

      // Stopping early should still leave something worth reviewing.
      expect(container.read(batchProvider).phase, BatchPhase.review);
    });

    test('reset clears everything', () async {
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'A': 0.9}),
      );
      await container.read(batchProvider.notifier).start([_song(1, 'A')]);

      container.read(batchProvider.notifier).reset();

      expect(container.read(batchProvider).phase, BatchPhase.idle);
      expect(container.read(batchProvider).candidates, isEmpty);
    });
  });

  // T14, T15 and T19 were one fault: the screen's `dispose` called `reset()`,
  // which emptied the candidate list under a loop that was still writing into it
  // by index. Hence a `RangeError` with "valid value range is empty", a scan
  // killed by the back arrow, and a restart that redid everything.
  group('a run that outlives its screen', () {
    /// Nine tracks: four batches of three, so there is genuinely a middle to
    /// interrupt.
    List<Song> nine() => [
      for (var i = 1; i <= 9; i++) _song(i, String.fromCharCode(64 + i)),
    ];

    test('resetting mid-flight does not throw', () async {
      final container = _containerWith(_FakeSource());
      final notifier = container.read(batchProvider.notifier);

      final run = notifier.start(nine());
      // Long enough to be inside the pause between two batches, which is where
      // the old code was when the screen went away.
      await Future.delayed(const Duration(milliseconds: 60));
      notifier.reset();

      await expectLater(run, completes);
    });

    test('an abandoned run stops publishing results', () async {
      // The crash was the visible half. The quiet half is a dead run stamping
      // its findings over whatever replaced it.
      final container = _containerWith(
        _FakeSource(
          confidenceByTitle: {for (final c in 'ABCDEFGHI'.split('')) c: 0.9},
        ),
      );
      final notifier = container.read(batchProvider.notifier);

      final run = notifier.start(nine());
      await Future.delayed(const Duration(milliseconds: 60));
      notifier.reset();
      await run;

      expect(container.read(batchProvider).candidates, isEmpty);
      expect(container.read(batchProvider).phase, BatchPhase.idle);
    });

    test('restarting on a shorter list after an interruption', () async {
      // T14 point 3, literally: start, interrupt, change the size of the list,
      // start again. The old index-into-shared-state would have been pointing
      // past the end of the new list.
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'A': 0.9, 'B': 0.9}),
      );
      final notifier = container.read(batchProvider.notifier);

      final first = notifier.start(nine());
      await Future.delayed(const Duration(milliseconds: 60));
      notifier.reset();
      await first;

      await notifier.start([_song(1, 'A'), _song(2, 'B')]);

      final state = container.read(batchProvider);
      expect(state.total, 2);
      expect(state.candidates, hasLength(2));
      expect(state.phase, BatchPhase.review);
    });

    test('reopening the screen does not restart a running scan', () async {
      final source = _FakeSource();
      final container = _containerWith(source);
      final notifier = container.read(batchProvider.notifier);

      final run = notifier.start(nine());
      await Future.delayed(const Duration(milliseconds: 60));

      // What `initState` does when the user comes back.
      await notifier.start(nine());
      await run;

      // Nine lookups, not eighteen.
      expect(source.queried, hasLength(9));
    });

    test(
      'reopening on a finished batch keeps it instead of researching',
      () async {
        final source = _FakeSource(confidenceByTitle: {'A': 0.9});
        final container = _containerWith(source);
        final notifier = container.read(batchProvider.notifier);

        await notifier.start([_song(1, 'A')]);
        await notifier.start([_song(1, 'A')]);

        expect(source.queried, ['A']);
        expect(container.read(batchProvider).phase, BatchPhase.review);
      },
    );

    test('a different list does start a new batch', () async {
      final source = _FakeSource(confidenceByTitle: {'A': 0.9, 'B': 0.9});
      final container = _containerWith(source);
      final notifier = container.read(batchProvider.notifier);

      await notifier.start([_song(1, 'A')]);
      await notifier.start([_song(2, 'B')]);

      expect(source.queried, ['A', 'B']);
      expect(container.read(batchProvider).candidates.single.song.title, 'B');
    });

    test(
      'the same tracks in a different order count as the same batch',
      () async {
        // The library's sort order can change while the batch screen is away.
        final source = _FakeSource(confidenceByTitle: {'A': 0.9, 'B': 0.9});
        final container = _containerWith(source);
        final notifier = container.read(batchProvider.notifier);

        final songs = [_song(1, 'A'), _song(2, 'B')];
        await notifier.start(songs);
        await notifier.start(songs.reversed.toList());

        expect(source.queried, hasLength(2));
      },
    );
  });

  group('writing twice', () {
    test('a track already written is not counted again', () async {
      // T15: an interrupted write run used to redo every file it had already
      // done. The count comes from the set of paths, so it cannot double up.
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'A': 0.9, 'B': 0.9}),
      );
      final notifier = container.read(batchProvider.notifier);
      await notifier.start([_song(1, 'A'), _song(2, 'B')]);

      notifier.beginWriting();
      notifier.recordWritten('/musique/A.mp3');
      notifier.recordWritten('/musique/A.mp3');

      expect(container.read(batchProvider).written, 1);
      expect(notifier.wasWritten('/musique/A.mp3'), isTrue);
      expect(notifier.wasWritten('/musique/B.mp3'), isFalse);
    });

    test('beginWriting keeps what an interrupted run already wrote', () async {
      // Pressing "Écrire" again after coming back must resume, not restart —
      // which means the counter cannot be zeroed here.
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'A': 0.9, 'B': 0.9}),
      );
      final notifier = container.read(batchProvider.notifier);
      await notifier.start([_song(1, 'A'), _song(2, 'B')]);

      notifier.beginWriting();
      notifier.recordWritten('/musique/A.mp3');
      notifier.beginWriting();

      expect(container.read(batchProvider).written, 1);
    });

    test('a new batch forgets what the last one wrote', () async {
      final container = _containerWith(
        _FakeSource(confidenceByTitle: {'A': 0.9}),
      );
      final notifier = container.read(batchProvider.notifier);
      await notifier.start([_song(1, 'A')]);
      notifier.recordWritten('/musique/A.mp3');

      notifier.reset();

      expect(notifier.wasWritten('/musique/A.mp3'), isFalse);
    });
  });

  group('what the batch actually asks for (T12)', () {
    /// A track the scanner could not read a tag from.
    Song untagged(int id, String title, String path) => Song(
      id: id,
      title: title,
      artist: MusicScanner.unknownArtist,
      album: MusicScanner.unknownAlbum,
      duration: 180000,
      filePath: path,
    );

    test('a placeholder artist is never sent as a search term', () async {
      // "Artiste inconnu" is a display string the scanner substitutes so the
      // library list reads properly. Sent to LRCLIB it is a French phrase
      // nobody recorded, so the query cannot match — and the album placeholder
      // drags the confidence score down on the ones that otherwise would.
      final source = _FakeSource();
      final container = _containerWith(source);

      await container.read(batchProvider.notifier).start([
        untagged(1, 'Snapchat', '/musique/Snapchat.mp3'),
      ]);

      expect(source.queries, isNotEmpty);
      for (final query in source.queries) {
        expect(query.artist, isNot(contains('inconnu')));
        expect(query.album, isNot('Album inconnu'));
      }
    });

    test('a miss is retried from the file name', () async {
      // The reader that unpicks `Mr SAYDA - MBA MARINA (Official Video).mp3`
      // was wired into the one-song search screen only, so the batch — the one
      // place looking at eighteen hundred files — searched the tags and stopped
      // there.
      final source = _FakeSource();
      final container = _containerWith(source);

      await container.read(batchProvider.notifier).start([
        untagged(1, '09', '/musique/Niska - Commando (Clip Officiel).mp3'),
      ]);

      expect(source.queries, hasLength(2));
      expect(source.queries.first.title, '09');
      expect(source.queries.last.title, 'Commando');
      expect(source.queries.last.artist, 'Niska');
    });

    test('a match found that way says so, and says what it asked', () async {
      final source = _FakeSource(confidenceByTitle: {'Commando': 0.9});
      final container = _containerWith(source);

      await container.read(batchProvider.notifier).start([
        untagged(1, '09', '/musique/Niska - Commando.mp3'),
      ]);

      final candidate = container.read(batchProvider).candidates.single;
      expect(candidate.hasMatch, isTrue);
      expect(candidate.viaFilename, isTrue);
      expect(candidate.queriedTitle, 'Commando');
      expect(candidate.queriedArtist, 'Niska');
    });

    test('a miss records what was asked, so it can be diagnosed', () async {
      // T12 asks why 1820 of 1876 miss. The answer is usually legible the
      // moment you can see the query — which needs the query kept.
      final source = _FakeSource();
      final container = _containerWith(source);

      await container.read(batchProvider.notifier).start([
        untagged(1, '09', '/musique/Niska - Commando.mp3'),
      ]);

      final candidate = container.read(batchProvider).candidates.single;
      expect(candidate.hasMatch, isFalse);
      expect(candidate.queriedTitle, 'Commando');
      expect(candidate.queriedArtist, 'Niska');
    });

    test('a strictly poorer second query is not made', () async {
      // The file name repeats the title and has no artist, while the tags had
      // one. Asking again would spend a request to ask a worse question.
      final source = _FakeSource();
      final container = _containerWith(source);

      await container.read(batchProvider.notifier).start([
        _song(1, 'Alors on danse'),
      ]);

      expect(source.queries, hasLength(1));
      expect(source.queries.single.artist, 'Artiste');
    });

    test('an identical second query is not made either', () async {
      final source = _FakeSource();
      final container = _containerWith(source);

      await container.read(batchProvider.notifier).start([
        Song(
          id: 1,
          title: 'Commando',
          artist: 'Niska',
          album: MusicScanner.unknownAlbum,
          duration: 180000,
          filePath: '/musique/Niska - Commando.mp3',
        ),
      ]);

      expect(source.queries, hasLength(1));
    });

    test('every track is looked up, however long each one takes', () async {
      // The workers share one cursor rather than taking a slice each: tracks
      // differ in how long they take, and a fixed slice per worker leaves some
      // finished while another still has a hundred to go.
      final source = _FakeSource();
      final container = _containerWith(source);
      final songs = [for (var i = 1; i <= 25; i++) _song(i, 'T$i')];

      await container.read(batchProvider.notifier).start(songs);

      final state = container.read(batchProvider);
      expect(state.done, 25);
      expect(state.candidates, hasLength(25));
      expect(state.phase, BatchPhase.review);
      expect(
        source.queried.toSet(),
        containsAll([for (var i = 1; i <= 25; i++) 'T$i']),
      );
    });
  });
}
