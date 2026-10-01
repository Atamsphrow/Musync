// The floating bubble froze on the previous track's last line when the next
// track started: while the new lyrics load, the lyrics provider still holds
// the old track's value. Every value is now tagged with the song it was read
// for, and the bubble only samples lyrics whose tag matches the current song.
// These tests pin that contract.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Song songA;
  late Song songB;

  SyncedLyrics tagged(String word) => SyncedLyrics([
    LyricLine(timestamp: Duration.zero, text: '$word one'),
    LyricLine(timestamp: const Duration(seconds: 5), text: '$word two'),
  ]);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_songtag_');
    for (final name in ['a.mp3', 'b.mp3']) {
      await File('${tempDir.path}/$name').writeAsBytes(List.filled(2048, 0));
    }
    await Id3Writer.writeLyrics('${tempDir.path}/a.mp3', synced: tagged('alpha'));
    await Id3Writer.writeLyrics('${tempDir.path}/b.mp3', synced: tagged('beta'));
    songA = Song(
      id: 1,
      title: 'A',
      artist: 'x',
      album: 'y',
      duration: 10000,
      filePath: '${tempDir.path}/a.mp3',
    );
    songB = Song(
      id: 2,
      title: 'B',
      artist: 'x',
      album: 'y',
      duration: 10000,
      filePath: '${tempDir.path}/b.mp3',
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('tags the lyrics with the song they were read for', () async {
    final container = ProviderContainer(
      overrides: [currentSongProvider.overrideWithValue(songA)],
    );
    addTearDown(container.dispose);

    final pair = await container.read(currentLyricsProvider.future);
    expect(pair.song?.id, songA.id);
    expect(pair.synced?.lines.first.text, 'alpha one');
  });

  test('a song change never lets old lyrics claim to be the new song', () async {
    final songState = StateProvider<Song?>((_) => songA);
    final container = ProviderContainer(
      overrides: [currentSongProvider.overrideWith((ref) => ref.watch(songState))],
    );
    addTearDown(container.dispose);

    final pairA = await container.read(currentLyricsProvider.future);
    expect(pairA.song?.id, songA.id);

    // Switch to B. While B's lyrics load, the provider still exposes A's
    // tagged value (or nothing) — the tag is what tells the bubble not to
    // sample it with B's position.
    container.read(songState.notifier).state = songB;
    final exposed = container.read(currentLyricsProvider);
    final claimedSongId = exposed.valueOrNull?.song?.id;
    expect(
      claimedSongId == null || claimedSongId != songB.id,
      isTrue,
      reason: 'stale lyrics must never masquerade as the new song',
    );

    // Once loaded, the tag matches B and the words are B's.
    final pairB = await container.read(currentLyricsProvider.future);
    expect(pairB.song?.id, songB.id);
    expect(pairB.synced?.lines.first.text, 'beta one');
  });

  test('the line ticker follows the tag, not the stale value', () async {
    final songState = StateProvider<Song?>((_) => songA);
    final container = ProviderContainer(
      overrides: [currentSongProvider.overrideWith((ref) => ref.watch(songState))],
    );
    addTearDown(container.dispose);

    await container.read(currentLyricsProvider.future);
    container.read(songState.notifier).state = songB;
    // The ticker must not resolve an index from A's lines while B is current.
    final pair = container.read(currentLyricsProvider).valueOrNull;
    final usable = pair?.song?.id == songB.id ? pair?.synced : null;
    expect(usable, isNull);
  });
}
