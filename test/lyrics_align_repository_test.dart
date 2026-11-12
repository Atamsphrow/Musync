// Tests du crochet d'alignement dans le dépôt : des timings LyricsPlus /
// lrc.red sont recalés sur les timings du fichier avant écriture ; tout
// le reste est écrit tel quel.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/lyrics_word_timings_store.dart';

const texts = [
  'Première ligne du morceau',
  'Deuxième ligne du morceau',
  'Troisième ligne du morceau',
];

SyncedLyrics lines(List<(int, String)> spec, {bool withWords = false}) =>
    SyncedLyrics([
      for (final (ms, text) in spec)
        LyricLine(
          timestamp: Duration(milliseconds: ms),
          text: text,
          words: withWords && text == texts[0]
              ? const [
                  LyricWord(
                    start: Duration(milliseconds: 4000),
                    duration: Duration(milliseconds: 500),
                    text: 'Première',
                  ),
                  LyricWord(
                    start: Duration(milliseconds: 4500),
                    duration: Duration(milliseconds: 500),
                    text: 'ligne',
                  ),
                ]
              : const [],
        ),
    ]);

void main() {
  late Directory tmp;
  late Directory root;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lyrics_align_repo_');
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

  Future<List<int>> writtenTimes(File file) async {
    final pair = await Id3Reader.readLyricsFrames(file.path);
    return [
      for (final line in pair.synced!.lines) line.timestamp!.inMilliseconds,
    ];
  }

  test('drapeau levé : les timings sont recalés sur le fichier', () async {
    final repository = LyricsRepository();
    final file = await writeMp3('a.mp3');
    // Les timings déjà dans le fichier : +2000 ms par rapport à l'entrant.
    await repository.embedLyrics(
      file.path,
      synced: lines([
        (6000, texts[0]),
        (12000, texts[1]),
        (18000, texts[2]),
      ]),
    );
    await repository.embedLyrics(
      file.path,
      synced: lines([
        (4000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
      ]),
      alignToExisting: true,
    );
    expect(await writtenTimes(file), [6000, 12000, 18000]);
  });

  test('drapeau baissé : écrits tels quels', () async {
    final repository = LyricsRepository();
    final file = await writeMp3('b.mp3');
    await repository.embedLyrics(
      file.path,
      synced: lines([
        (6000, texts[0]),
        (12000, texts[1]),
        (18000, texts[2]),
      ]),
    );
    await repository.embedLyrics(
      file.path,
      synced: lines([
        (4000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
      ]),
    );
    expect(await writtenTimes(file), [4000, 10000, 16000]);
  });

  test('drapeau levé, fichier sans paroles : écrits tels quels', () async {
    final repository = LyricsRepository();
    final file = await writeMp3('c.mp3');
    await repository.embedLyrics(
      file.path,
      synced: lines([
        (4000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
      ]),
      alignToExisting: true,
    );
    expect(await writtenTimes(file), [4000, 10000, 16000]);
  });

  test('écarts en désaccord : écrits tels quels, pas de refus', () async {
    final repository = LyricsRepository();
    final file = await writeMp3('d.mp3');
    await repository.embedLyrics(
      file.path,
      synced: lines([
        (6000, texts[0]),
        (12000, texts[1]),
        (18000, texts[2]),
      ]),
    );
    await repository.embedLyrics(
      file.path,
      synced: lines([
        (4000, texts[0]),
        (11000, texts[1]),
        (21000, texts[2]),
      ]),
      alignToExisting: true,
    );
    expect(await writtenTimes(file), [4000, 11000, 21000]);
  });

  test('mots alignés : le karaoké suit le décalage', () async {
    final store = LyricsWordTimingsStore(root: root);
    final repository = LyricsRepository(wordTimingsStore: store);
    final file = await writeMp3('e.mp3');
    await repository.embedLyrics(
      file.path,
      synced: lines([
        (6000, texts[0]),
        (12000, texts[1]),
        (18000, texts[2]),
      ]),
    );
    await repository.embedLyrics(
      file.path,
      synced: lines([
        (4000, texts[0]),
        (10000, texts[1]),
        (16000, texts[2]),
      ], withWords: true),
      alignToExisting: true,
    );
    // Les mots sont sauvés avec leurs offsets relatifs : rattachés aux
    // lignes écrites (6000…), ils tombent à 6000/6500, pas à 4000/4500.
    final attached = await store.attachWords(
      file.path,
      lines([
        (6000, texts[0]),
        (12000, texts[1]),
        (18000, texts[2]),
      ]),
    );
    final first = attached.lines.singleWhere((l) => l.text == texts[0]);
    expect(first.words.map((w) => w.start.inMilliseconds), [6000, 6500]);
  });
}
