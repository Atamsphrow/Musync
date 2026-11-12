// Tests du crochet de sauve des mots dans le dépôt : chaque écriture de
// paroles mot à mot sauve les mots côté app ; une écriture sans mots ne
// touche pas au store.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/lyrics_word_timings_store.dart';

SyncedLyrics wordTimed() => SyncedLyrics([
  LyricLine(
    timestamp: const Duration(milliseconds: 4000),
    text: 'Une ligne',
    words: const [
      LyricWord(
        start: Duration(milliseconds: 4000),
        duration: Duration(milliseconds: 500),
        text: 'Une',
      ),
      LyricWord(
        start: Duration(milliseconds: 4500),
        duration: Duration(milliseconds: 500),
        text: 'ligne',
      ),
    ],
  ),
]);

SyncedLyrics lineOnly() => SyncedLyrics([
  const LyricLine(timestamp: Duration(milliseconds: 4000), text: 'Une ligne'),
]);

void main() {
  late Directory tmp;
  late Directory root;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lyrics_word_repo_');
    root = Directory('${tmp.path}/support')..createSync();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<File> writeMp3(String name) async {
    final file = File('${tmp.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(List<int>.generate(4096, (i) => i & 0xFF));
    return file;
  }

  test('embed mot à mot : les mots sont dans le store après', () async {
    final store = LyricsWordTimingsStore(root: root);
    final repository = LyricsRepository(wordTimingsStore: store);
    final file = await writeMp3('a.mp3');
    await repository.embedLyrics(file.path, synced: wordTimed());
    final attached = await store.attachWords(file.path, lineOnly());
    expect(attached.lines.single.words, hasLength(2));
    expect(attached.lines.single.words[0].start,
        const Duration(milliseconds: 4000));
  });

  test('embed sans mots : le store n\'est pas touché', () async {
    final store = LyricsWordTimingsStore(root: root);
    final repository = LyricsRepository(wordTimingsStore: store);
    final file = await writeMp3('b.mp3');
    await repository.embedLyrics(file.path, synced: wordTimed());
    // Une sauve d'éditeur (lignes seules, mêmes textes) : les mots restent.
    await repository.embedLyrics(file.path, synced: lineOnly());
    final attached = await store.attachWords(file.path, lineOnly());
    expect(attached.lines.single.words, hasLength(2));
  });

  test('sans store injecté : embed fonctionne pareil', () async {
    final repository = LyricsRepository();
    final file = await writeMp3('c.mp3');
    await repository.embedLyrics(file.path, synced: wordTimed());
  });
}
