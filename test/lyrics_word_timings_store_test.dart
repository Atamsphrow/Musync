// Tests du store des timings mot à mot (karaoké).
//
// Le contrat : les mots survivent à un redémarrage, suivent un décalage de
// ligne sans aucune écriture (offsets relatifs), et ne s'attachent jamais
// à des paroles dont le texte a changé.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/lyrics_word_timings_store.dart';

SyncedLyrics wordTimed({int lineAt = 4000}) => SyncedLyrics([
  LyricLine(
    timestamp: Duration(milliseconds: lineAt),
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
        isBackground: true,
      ),
    ],
  ),
  const LyricLine(timestamp: Duration(milliseconds: 6000), text: 'Suivante'),
]);

SyncedLyrics plain({int lineAt = 4000}) => SyncedLyrics([
  LyricLine(timestamp: Duration(milliseconds: lineAt), text: 'Une ligne'),
  const LyricLine(timestamp: Duration(milliseconds: 6000), text: 'Suivante'),
]);

void main() {
  late Directory tmp;
  late Directory root;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lyrics_word_timings_');
    root = Directory('${tmp.path}/support')..createSync();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  LyricsWordTimingsStore store() => LyricsWordTimingsStore(root: root);

  test('aller-retour : offsets relatifs, durées et chœur conservés', () async {
    final s = store();
    await s.saveWords('/m/1.mp3', wordTimed());
    await s.save();
    final attached = await s.attachWords('/m/1.mp3', plain());
    final line = attached.lines.singleWhere((l) => l.text == 'Une ligne');
    expect(line.words, hasLength(2));
    expect(line.words[0].start, const Duration(milliseconds: 4000));
    expect(line.words[0].duration, const Duration(milliseconds: 500));
    expect(line.words[0].text, 'Une');
    expect(line.words[0].isBackground, isFalse);
    expect(line.words[1].start, const Duration(milliseconds: 4500));
    expect(line.words[1].isBackground, isTrue);
  });

  test('les mots survivent à un redémarrage (nouvelle instance)', () async {
    final s = store();
    await s.saveWords('/m/2.mp3', wordTimed());
    await s.save();
    final reloaded = LyricsWordTimingsStore(root: root);
    final attached = await reloaded.attachWords('/m/2.mp3', plain());
    expect(attached.lines.first.words, hasLength(2));
  });

  test('décalage de ligne : les mots suivent sans réécriture', () async {
    final s = store();
    await s.saveWords('/m/3.mp3', wordTimed());
    await s.save();
    // La ligne a été décalée de +100 ms (nudge) : les mots doivent
    // arriver à 4100 et 4600 ms, pas à 4000 et 4500.
    final attached = await s.attachWords('/m/3.mp3', plain(lineAt: 4100));
    final line = attached.lines.singleWhere((l) => l.text == 'Une ligne');
    expect(line.timestamp, const Duration(milliseconds: 4100));
    expect(line.words[0].start, const Duration(milliseconds: 4100));
    expect(line.words[1].start, const Duration(milliseconds: 4600));
  });

  test('texte édité : les mots ne s\'attachent plus', () async {
    final s = store();
    await s.saveWords('/m/4.mp3', wordTimed());
    await s.save();
    final edited = SyncedLyrics([
      const LyricLine(
        timestamp: Duration(milliseconds: 4000),
        text: 'Une autre ligne',
      ),
      const LyricLine(
        timestamp: Duration(milliseconds: 6000),
        text: 'Suivante',
      ),
    ]);
    final attached = await s.attachWords('/m/4.mp3', edited);
    expect(identical(attached, edited), isTrue);
    expect(attached.hasWordTimings, isFalse);
  });

  test('autre chemin : les mots ne s\'attachent pas', () async {
    final s = store();
    await s.saveWords('/m/5.mp3', wordTimed());
    await s.save();
    final attached = await s.attachWords('/m/autre.mp3', plain());
    expect(attached.hasWordTimings, isFalse);
  });

  test('sauver sans mots : no-op, l\'entrée existante survit', () async {
    final s = store();
    await s.saveWords('/m/6.mp3', wordTimed());
    await s.save();
    // Une sauve d'éditeur (sans mots) ne doit pas effacer le karaoké.
    await s.saveWords('/m/6.mp3', plain());
    await s.save();
    final attached = await s.attachWords('/m/6.mp3', plain());
    expect(attached.lines.first.words, hasLength(2));
  });

  test('fichier illisible : pas de mots, pas d\'erreur', () async {
    final file = File('${root.path}/lyrics_word_timings.json');
    await file.writeAsString('ceci n’est pas du json');
    final attached = await store().attachWords('/m/7.mp3', plain());
    expect(attached.hasWordTimings, isFalse);
    // Et la sauve reste possible par-dessus le fichier cassé.
    final s = store();
    await s.saveWords('/m/7.mp3', wordTimed());
    await s.save();
    expect(jsonDecode(await file.readAsString()), isA<Map>());
  });

  test('entrée mal formée dans le fichier : ignorée, les autres restent',
      () async {
    final file = File('${root.path}/lyrics_word_timings.json');
    await file.writeAsString(
      jsonEncode({
        '/m/8.mp3': {'hash': 'zzz', 'lines': 'pas une liste'},
        '/m/9.mp3': {
          'hash': lyricsWordsHash(plain()),
          'lines': {
            '0': [
              {
                'offsetMs': 0,
                'durationMs': 500,
                'text': 'Une',
                'isBackground': false,
              },
              {
                'offsetMs': 500,
                'durationMs': 500,
                'text': 'ligne',
                'isBackground': false,
              },
            ],
          },
        },
      }),
    );
    final s = store();
    expect((await s.attachWords('/m/8.mp3', plain())).hasWordTimings,
        isFalse);
    final attached = await s.attachWords('/m/9.mp3', plain());
    expect(attached.lines.first.words, hasLength(2));
    expect(attached.lines.first.words[1].start,
        const Duration(milliseconds: 4500));
  });
}
