import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/lyrics_word_timings_store.dart';

LyricWord _mot(String text, int startMs, int durMs) => LyricWord(
  start: Duration(milliseconds: startMs),
  duration: Duration(milliseconds: durMs),
  text: text,
);

List<LyricWord> _fragments() => [
  _mot('Per', 1000, 200),
  _mot('co', 1200, 200),
  _mot('cet', 1400, 300),
];

SyncedLyrics _avantEdition() => SyncedLyrics([
  LyricLine(
    timestamp: const Duration(milliseconds: 1000),
    text: 'Per co cet',
    words: _fragments(),
  ),
  const LyricLine(timestamp: Duration(milliseconds: 5000), text: 'ligne deux'),
]);

/// Même chose après fusion des fragments dans l'éditeur : le texte change,
/// les mots restent.
SyncedLyrics _apresEdition() => SyncedLyrics([
  LyricLine(
    timestamp: const Duration(milliseconds: 1000),
    text: 'Percocet',
    words: _fragments(),
  ),
  const LyricLine(timestamp: Duration(milliseconds: 5000), text: 'ligne deux'),
]);

/// Les paroles du fichier, telles que l'éditeur les relit : texte seul.
SyncedLyrics _sansMots(SyncedLyrics s) => SyncedLyrics([
  for (final l in s.lines) LyricLine(timestamp: l.timestamp, text: l.text),
]);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('musync_words_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  const chemin = '/musique/juice.mp3';

  group('re-clé du store après édition du texte', () {
    test('le hash change quand on fusionne les fragments', () {
      expect(
        lyricsWordsHash(_avantEdition()),
        isNot(lyricsWordsHash(_apresEdition())),
      );
    });

    test('texte édité, mots non re-sauvés : les mots ne s\'attachent plus',
        () async {
      final store = LyricsWordTimingsStore(root: dir);
      await store.saveWords(chemin, _avantEdition());
      final fichier = _sansMots(_apresEdition());
      final res = await store.attachWords(chemin, fichier);
      expect(identical(res, fichier), isTrue);
      expect(res.lines.first.hasWordTimings, isFalse);
    });

    test('sauver de nouveau avec le texte édité : attachWords retrouve les '
        'mots', () async {
      final store = LyricsWordTimingsStore(root: dir);
      await store.saveWords(chemin, _avantEdition());
      await store.saveWords(chemin, _apresEdition());

      final res = await store.attachWords(chemin, _sansMots(_apresEdition()));
      final ligne = res.lines.first;
      expect(ligne.text, 'Percocet');
      expect(ligne.words.map((w) => w.text), ['Per', 'co', 'cet']);
      expect(ligne.words.map((w) => w.start.inMilliseconds), [1000, 1200, 1400]);
      expect(ligne.words.map((w) => w.duration.inMilliseconds), [200, 200, 300]);
      // L'autre ligne n'est pas affectée.
      expect(res.lines[1].hasWordTimings, isFalse);
    });

    test('l\'ancien texte n\'attache plus rien : l\'entrée est remplacée',
        () async {
      final store = LyricsWordTimingsStore(root: dir);
      await store.saveWords(chemin, _avantEdition());
      await store.saveWords(chemin, _apresEdition());
      final ancien = _sansMots(_avantEdition());
      expect(identical(await store.attachWords(chemin, ancien), ancien), isTrue);
    });

    test('décalages préservés quand la ligne est retimée', () async {
      final store = LyricsWordTimingsStore(root: dir);
      await store.saveWords(chemin, _apresEdition());
      final retime = SyncedLyrics([
        const LyricLine(timestamp: Duration(milliseconds: 3000), text: 'Percocet'),
        const LyricLine(timestamp: Duration(milliseconds: 7000), text: 'ligne deux'),
      ]);
      final res = await store.attachWords(chemin, retime);
      expect(
        res.lines.first.words.map((w) => w.start.inMilliseconds),
        [3000, 3200, 3400],
      );
    });

    test('survit à un redémarrage (save puis nouveau store)', () async {
      final store = LyricsWordTimingsStore(root: dir);
      await store.saveWords(chemin, _avantEdition());
      await store.saveWords(chemin, _apresEdition());
      await store.save();

      final relu = LyricsWordTimingsStore(root: dir);
      final res = await relu.attachWords(chemin, _sansMots(_apresEdition()));
      expect(res.lines.first.words.map((w) => w.text), ['Per', 'co', 'cet']);
    });

    test('saveWords sans mots ne supprime pas l\'entrée existante', () async {
      final store = LyricsWordTimingsStore(root: dir);
      await store.saveWords(chemin, _apresEdition());
      await store.saveWords(chemin, _sansMots(_apresEdition()));
      final res = await store.attachWords(chemin, _sansMots(_apresEdition()));
      expect(res.lines.first.hasWordTimings, isTrue);
    });
  });
}
