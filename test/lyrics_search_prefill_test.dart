// The lyrics search screen: what it searches for first, and what « Deviner
// Artiste/Titre » does.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/lyrics/ui/lyrics_search_screen.dart';

typedef _Query = ({String title, String artist, FilenameGuess? guess});

class _RecordingSource extends LyricsSource {
  final queries = <_Query>[];

  @override
  String get name => 'Témoin';

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    queries.add((title: title, artist: artist, guess: filenameGuess));
    return [
      LyricsSearchResult(
        source: name,
        title: title,
        artist: artist,
        syncedLyrics: SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'La la'),
        ]),
        confidence: 0.9,
      ),
    ];
  }
}

Future<_RecordingSource> _open(WidgetTester tester, Song song) async {
  final source = _RecordingSource();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        lyricsRepositoryProvider.overrideWithValue(
          LyricsRepository(sources: [source]),
        ),
      ],
      child: MaterialApp(home: LyricsSearchScreen(song: song)),
    ),
  );
  await tester.pump();
  await tester.pump();
  return source;
}

void main() {
  testWidgets('good tags are searched as they are, not the file name',
      (tester) async {
    final source = await _open(
      tester,
      const Song(
        id: 1,
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
        album: 'A Night at the Opera',
        duration: 354000,
        filePath: '/m/Queen - Bohemian Rhapsody (Remastered 2011).mp3',
      ),
    );
    expect(source.queries.first.title, 'Bohemian Rhapsody');
    expect(source.queries.first.artist, 'Queen');
    // The file name's guess still reaches the ranking.
    expect(source.queries.first.guess?.artist, 'Queen');
  });

  testWidgets('an unknown artist and a raw title come from the file name',
      (tester) async {
    final source = await _open(
      tester,
      const Song(
        id: 2,
        title: 'ALG - Biloo (Official Video)',
        artist: '<unknown>',
        album: '',
        duration: 200000,
        filePath: '/m/ALG - Biloo (Official Video).mp3',
      ),
    );
    expect(source.queries.first.title, 'Biloo');
    expect(source.queries.first.artist, 'ALG');
  });

  testWidgets('Deviner fills the fields and searches with them',
      (tester) async {
    final source = await _open(
      tester,
      const Song(
        id: 3,
        title: 'Biloo',
        artist: 'Someone Else',
        album: '',
        duration: 200000,
        filePath: '/m/ALG - Biloo.mp3',
      ),
    );
    expect(source.queries.single.artist, 'Someone Else');

    await tester.tap(find.text('Deviner Artiste/Titre'));
    await tester.pump();
    await tester.pump();

    expect(source.queries, hasLength(2));
    expect(source.queries.last.artist, 'ALG');
    expect(source.queries.last.title, 'Biloo');
  });

  testWidgets('Deviner on fields that already say it does not search again',
      (tester) async {
    final source = await _open(
      tester,
      const Song(
        id: 4,
        title: 'Biloo',
        artist: 'ALG',
        album: '',
        duration: 200000,
        filePath: '/m/ALG - Biloo.mp3',
      ),
    );
    await tester.tap(find.text('Deviner Artiste/Titre'));
    await tester.pump();
    await tester.pump();

    expect(source.queries, hasLength(1));
    expect(find.textContaining('disent déjà'), findsOneWidget);
  });
}
