import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/lyrics_word_timings_store.dart';
import 'package:musync/features/sync_editor/providers/sync_editor_provider.dart';

LyricWord _mot(String text, int startMs, int durMs, {bool bg = false}) =>
    LyricWord(
      start: Duration(milliseconds: startMs),
      duration: Duration(milliseconds: durMs),
      text: text,
      isBackground: bg,
    );

LyricLine _ligneMots() => LyricLine(
  timestamp: const Duration(milliseconds: 1000),
  text: 'Per co cet',
  words: [_mot('Per', 1000, 200), _mot('co', 1200, 200), _mot('cet', 1400, 300)],
);

SyncedLyrics _synchronisees() => SyncedLyrics([
  _ligneMots(),
  const LyricLine(timestamp: Duration(milliseconds: 5000), text: 'ligne deux'),
]);

SyncedLyrics _sansMots(SyncedLyrics s) => SyncedLyrics([
  for (final l in s.lines) LyricLine(timestamp: l.timestamp, text: l.text),
]);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('musync_editor_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  const chemin = '/musique/juice.mp3';

  group('chargement de l\'éditeur', () {
    test('rattache les mots du store aux lignes synchronisées', () async {
      final store = LyricsWordTimingsStore(root: dir);
      await store.saveWords(chemin, _synchronisees());

      final lignes = await SyncEditorNotifier.loadedLines(
        filePath: chemin,
        synced: _sansMots(_synchronisees()),
        unsynced: null,
        store: store,
      );
      expect(lignes, hasLength(2));
      expect(lignes[0].words.map((w) => w.text), ['Per', 'co', 'cet']);
      expect(lignes[0].words.first.start, const Duration(milliseconds: 1000));
      expect(lignes[1].hasWordTimings, isFalse);
    });

    test('les lignes en plus de l\'USLT viennent APRÈS, sans heure ni mots',
        () async {
      final store = LyricsWordTimingsStore(root: dir);
      await store.saveWords(chemin, _synchronisees());

      final lignes = await SyncEditorNotifier.loadedLines(
        filePath: chemin,
        synced: _sansMots(_synchronisees()),
        unsynced: const UnsyncedLyrics('[Refrain]\nPer co cet\nligne deux'),
        store: store,
      );
      expect(lignes.map((l) => l.text), ['Per co cet', 'ligne deux', '[Refrain]']);
      expect(lignes[0].hasWordTimings, isTrue);
      expect(lignes[2].isTimed, isFalse);
      expect(lignes[2].hasWordTimings, isFalse);
    });

    test('texte modifié depuis le store : lignes sans mots, pas d\'erreur',
        () async {
      final store = LyricsWordTimingsStore(root: dir);
      await store.saveWords(chemin, _synchronisees());
      final modifiees = SyncedLyrics([
        const LyricLine(timestamp: Duration(milliseconds: 1000), text: 'Percocet'),
        const LyricLine(timestamp: Duration(milliseconds: 5000), text: 'ligne deux'),
      ]);
      final lignes = await SyncEditorNotifier.loadedLines(
        filePath: chemin,
        synced: modifiees,
        unsynced: null,
        store: store,
      );
      expect(lignes.any((l) => l.hasWordTimings), isFalse);
    });

    test('sans store : paroles telles quelles', () async {
      final lignes = await SyncEditorNotifier.loadedLines(
        filePath: chemin,
        synced: _sansMots(_synchronisees()),
        unsynced: null,
      );
      expect(lignes, hasLength(2));
      expect(lignes.any((l) => l.hasWordTimings), isFalse);
    });
  });

  group('les mutations conservent les mots', () {
    test('updateLineText (copyWith text) : mots conservés', () {
      final edite = _ligneMots().copyWith(text: 'Percocet');
      expect(edite.text, 'Percocet');
      expect(edite.words, _ligneMots().words);
    });

    test('clearTimestamp / resetTimings (withoutTimestamp) : mots conservés',
        () {
      final sans = _ligneMots().withoutTimestamp();
      expect(sans.isTimed, isFalse);
      expect(sans.words, _ligneMots().words);
    });

    test('retimedLine : les mots suivent la ligne', () {
      final deplacee = SyncEditorNotifier.retimedLine(
        _ligneMots(),
        const Duration(milliseconds: 3000),
      );
      expect(deplacee.timestamp, const Duration(milliseconds: 3000));
      expect(
        deplacee.words.map((w) => w.start.inMilliseconds),
        [3000, 3200, 3400],
      );
      expect(deplacee.words.map((w) => w.text), ['Per', 'co', 'cet']);
    });

    test('retimedLine : écart nul, mots inchangés', () {
      final meme = SyncEditorNotifier.retimedLine(
        _ligneMots(),
        const Duration(milliseconds: 1000),
      );
      expect(meme, _ligneMots());
    });

    test('retimedLine : jamais d\'heure négative pour un mot', () {
      final avance = SyncEditorNotifier.retimedLine(
        _ligneMots(),
        Duration.zero,
      );
      expect(avance.words.map((w) => w.start.inMilliseconds), [0, 200, 400]);
    });

    test('retimedLine : ligne sans mots, simple changement d\'heure', () {
      const ligne = LyricLine(timestamp: Duration(seconds: 1), text: 'a');
      final res = SyncEditorNotifier.retimedLine(ligne, const Duration(seconds: 2));
      expect(res.timestamp, const Duration(seconds: 2));
      expect(res.words, isEmpty);
    });

    test('retimedLine : ligne sans heure, le premier mot sert de référence',
        () {
      final res = SyncEditorNotifier.retimedLine(
        _ligneMots().withoutTimestamp(),
        const Duration(milliseconds: 2000),
      );
      expect(
        res.words.map((w) => w.start.inMilliseconds),
        [2000, 2200, 2400],
      );
    });
  });

  group('sauvegarde', () {
    test('éditer le texte puis sauver : le store a l\'entrée sous le nouveau '
        'hash', () async {
      final store = LyricsWordTimingsStore(root: dir);
      await store.saveWords(chemin, _synchronisees());

      // L'éditeur : lignes chargées, une ligne corrigée, état → SYLT.
      var etat = SyncEditorState(
        lines: await SyncEditorNotifier.loadedLines(
          filePath: chemin,
          synced: _sansMots(_synchronisees()),
          unsynced: null,
          store: store,
        ),
        isLoading: false,
      );
      final lignes = [...etat.lines];
      lignes[0] = lignes[0].copyWith(text: 'Percocet');
      etat = etat.copyWith(lines: lignes);

      // Ce que fait embedLyrics : saveWords + save pour des lignes à mots.
      expect(etat.asSyncedLyrics.hasWordTimings, isTrue);
      await store.saveWords(chemin, etat.asSyncedLyrics);
      await store.save();

      // Rechargement : le fichier relit « Percocet » en texte seul.
      final relu = LyricsWordTimingsStore(root: dir);
      final fichier = SyncedLyrics([
        const LyricLine(timestamp: Duration(milliseconds: 1000), text: 'Percocet'),
        const LyricLine(timestamp: Duration(milliseconds: 5000), text: 'ligne deux'),
      ]);
      final res = await relu.attachWords(chemin, fichier);
      expect(res.lines[0].words.map((w) => w.text), ['Per', 'co', 'cet']);
      expect(res.lines[1].hasWordTimings, isFalse);
    });

    test('nudger une ligne dans l\'éditeur puis sauver : les mots restent '
        'calés sur leur ligne', () async {
      final store = LyricsWordTimingsStore(root: dir);
      final decalee = SyncEditorNotifier.retimedLine(
        _ligneMots(),
        const Duration(milliseconds: 1500),
      );
      await store.saveWords(chemin, SyncedLyrics([decalee]));
      final res = await store.attachWords(
        chemin,
        SyncedLyrics([
          const LyricLine(timestamp: Duration(milliseconds: 1500), text: 'Per co cet'),
        ]),
      );
      expect(res.lines.first.words.map((w) => w.start.inMilliseconds),
          [1500, 1700, 1900]);
    });
  });
}
