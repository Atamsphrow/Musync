import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/data/karaoke_words.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/ui/widgets/karaoke_separators.dart';

LyricWord _w(String text, int startMs, int durMs, {bool bg = false}) =>
    LyricWord(
      start: Duration(milliseconds: startMs),
      duration: Duration(milliseconds: durMs),
      text: text,
      isBackground: bg,
    );

LyricLine _l(int ms, String text, [List<LyricWord> words = const []]) =>
    LyricLine(timestamp: Duration(milliseconds: ms), text: text, words: words);

/// Back to back, in order, each starting where the previous one ends.
void _expectContiguous(List<LyricWord> words) {
  for (var i = 1; i < words.length; i++) {
    expect(
      words[i].start,
      words[i - 1].start + words[i - 1].duration,
      reason: 'mot $i',
    );
  }
}

int _endMs(LyricWord w) => (w.start + w.duration).inMilliseconds;

void main() {
  group('karaokeTokens', () {
    test('mots séparés par des espaces, espaces en trop ignorés', () {
      expect(karaokeTokens('Hello world'), ['Hello', 'world']);
      expect(karaokeTokens('  a   b '), ['a', 'b']);
      expect(karaokeTokens('Hello '), ['Hello']);
      expect(karaokeTokens('   '), isEmpty);
    });

    test('la ponctuation reste avec son mot', () {
      expect(karaokeTokens('(Hello), world!'), ['(Hello),', 'world!']);
      expect(karaokeTokens("Je t'aime, can’t stop"), [
        'Je',
        "t'aime,",
        'can’t',
        'stop',
      ]);
    });

    test('han et kana : un mot par caractère', () {
      expect(karaokeTokens('我爱你'), ['我', '爱', '你']);
      expect(karaokeTokens('你好，世界。'), ['你', '好，', '世', '界。']);
      expect(karaokeTokens('「你好」'), ['「你', '好」']);
      expect(karaokeTokens('ラーメン'), ['ラー', 'メ', 'ン']);
      expect(karaokeTokens('baby你 girl'), ['baby', '你', 'girl']);
    });

    test('le hangul garde ses mots entiers', () {
      expect(karaokeTokens('사랑해 너를'), ['사랑해', '너를']);
    });
  });

  group('prepareKaraokeWords : découpe des blocs', () {
    test('espace final dans le mot : chaque mot est une unité', () {
      // The shape that glued a whole line into one karaoke unit.
      final synced = SyncedLyrics([
        _l(0, 'Hello big world', [
          _w('Hello ', 0, 500),
          _w('big ', 500, 300),
          _w('world', 800, 700),
        ]),
      ]);
      final line = prepareKaraokeWords(synced, estimateUntimed: false).lines.single;
      expect(line.words.map((w) => w.text), ['Hello', 'big', 'world']);
      expect(line.words.map((w) => w.start.inMilliseconds), [0, 500, 800]);
      expect(karaokeWordSeparators(line), [' ', ' ']);
      expect(karaokeWordUnits(line), hasLength(3));
    });

    test('un bloc de plusieurs mots : découpé, temps au prorata', () {
      final synced = SyncedLyrics([
        _l(1000, 'Hello big world', [_w('Hello big world', 1000, 3200)]),
      ]);
      final words =
          prepareKaraokeWords(synced, estimateUntimed: false).lines.single.words;
      expect(words.map((w) => w.text), ['Hello', 'big', 'world']);
      // Weights 6, 4, 6 (letters + 1) over 3200 ms.
      expect(words.map((w) => w.duration.inMilliseconds), [1200, 800, 1200]);
      expect(words.first.start, const Duration(milliseconds: 1000));
      expect(_endMs(words.last), 4200);
      _expectContiguous(words);
    });

    test('les syllabes collées ne bougent pas, et rien ne change', () {
      final synced = SyncedLyrics([
        _l(0, 'never again', [
          _w('nev', 0, 200),
          _w('er', 200, 200),
          _w('again', 400, 500),
        ]),
      ]);
      expect(
        identical(prepareKaraokeWords(synced, estimateUntimed: true), synced),
        isTrue,
      );
    });

    test('la voix de chœur est gardée par mot', () {
      final synced = SyncedLyrics([
        _l(0, 'oh yeah', [_w('oh yeah', 0, 1000, bg: true)]),
      ]);
      final words =
          prepareKaraokeWords(synced, estimateUntimed: false).lines.single.words;
      expect(words.every((w) => w.isBackground), isTrue);
    });

    test('han : chaque caractère devient son unité', () {
      final synced = SyncedLyrics([
        _l(0, '我爱你', [_w('我', 0, 300), _w('爱', 300, 300), _w('你', 600, 300)]),
      ]);
      final line = prepareKaraokeWords(synced, estimateUntimed: false).lines.single;
      expect(karaokeWordUnits(line).map((u) => u.text), ['我', '爱', '你']);
    });

    test('un bloc han de plusieurs caractères est découpé', () {
      final synced = SyncedLyrics([
        _l(0, '我爱你', [_w('我爱你', 0, 900)]),
      ]);
      final words =
          prepareKaraokeWords(synced, estimateUntimed: false).lines.single.words;
      expect(words.map((w) => w.text), ['我', '爱', '你']);
      expect(words.map((w) => w.duration.inMilliseconds), [300, 300, 300]);
    });
  });

  group('prepareKaraokeWords : mot à mot estimé', () {
    test('éteint : une ligne sans mots reste sans mots', () {
      final synced = SyncedLyrics([_l(0, 'Hello world'), _l(4000, 'Next')]);
      expect(
        identical(prepareKaraokeWords(synced, estimateUntimed: false), synced),
        isTrue,
      );
    });

    test('ligne suivie d’une pause : rythme chanté ordinaire', () {
      final synced = SyncedLyrics([_l(0, 'Hello world'), _l(8000, 'Next line')]);
      final words =
          prepareKaraokeWords(synced, estimateUntimed: true).lines.first.words;
      expect(words.map((w) => w.text), ['Hello', 'world']);
      // Weights 6 + 6, at 130 ms each: 1560 ms, well before the next line.
      expect(words.first.start, Duration.zero);
      expect(_endMs(words.last), 1560);
      _expectContiguous(words);
    });

    test('ligne rapide : finit avant la ligne suivante', () {
      final synced = SyncedLyrics([
        _l(10000, 'one two three four five six seven'),
        _l(11000, 'Next'),
      ]);
      final words =
          prepareKaraokeWords(synced, estimateUntimed: true).lines.first.words;
      expect(words, hasLength(7));
      expect(words.first.start, const Duration(milliseconds: 10000));
      // 90 % of the 1000 ms to the next line.
      expect(_endMs(words.last), 10900);
      _expectContiguous(words);
    });

    test('ligne courte : jamais moins d’une seconde', () {
      final synced = SyncedLyrics([_l(0, 'Oh'), _l(9000, 'Next')]);
      final word =
          prepareKaraokeWords(synced, estimateUntimed: true).lines.first.words.single;
      expect(word.duration, kEstimatedMinLineTime);
    });

    test('même heure que la suivante : la ligne d’après compte', () {
      final synced = SyncedLyrics([
        _l(0, 'lead vocal line here'),
        _l(0, 'choir answers here too'),
        _l(2000, 'Next'),
      ]);
      final lines = prepareKaraokeWords(synced, estimateUntimed: true).lines;
      // 21 and 23 weights at 130 ms, both capped by 90 % of the 2000 ms
      // to the next line at a later time — not by the 0 ms to the twin.
      expect(_endMs(lines.first.words.last), 1800);
      expect(_endMs(lines[1].words.last), 1800);
    });

    test('mots incohérents avec le texte : réestimés sur leur durée', () {
      final synced = SyncedLyrics([
        _l(0, 'Hello world', [_w('Bonjour', 200, 400), _w('monde', 600, 800)]),
      ]);
      final words =
          prepareKaraokeWords(synced, estimateUntimed: true).lines.single.words;
      expect(words.map((w) => w.text), ['Hello', 'world']);
      expect(words.first.start, const Duration(milliseconds: 200));
      expect(_endMs(words.last), 1400);
    });

    test('lignes, textes, heures et romanisation inchangés', () {
      final synced = SyncedLyrics([
        const LyricLine(
          timestamp: Duration(milliseconds: 0),
          text: '我爱你',
          romanization: 'wǒ ài nǐ',
          voice: 2,
        ),
        _l(3000, 'Hello world'),
      ]);
      final prepared = prepareKaraokeWords(synced, estimateUntimed: true);
      expect(prepared.lines, hasLength(2));
      for (var i = 0; i < 2; i++) {
        expect(prepared.lines[i].text, synced.lines[i].text);
        expect(prepared.lines[i].timestamp, synced.lines[i].timestamp);
        expect(prepared.lines[i].voice, synced.lines[i].voice);
        expect(prepared.lines[i].romanization, synced.lines[i].romanization);
        expect(karaokeWordSeparators(prepared.lines[i]), isNotNull);
      }
      expect(prepared.lines.first.words.map((w) => w.text), ['我', '爱', '你']);
    });

    test('le mot courant avance mot par mot sur une ligne estimée', () {
      final prepared = prepareKaraokeWords(
        SyncedLyrics([_l(0, 'Hello world'), _l(8000, 'Next')]),
        estimateUntimed: true,
      );
      expect(currentWordAt(prepared, const Duration(milliseconds: 100)), (
        lineIndex: 0,
        wordIndex: 0,
      ));
      expect(currentWordAt(prepared, const Duration(milliseconds: 1000)), (
        lineIndex: 0,
        wordIndex: 1,
      ));
    });
  });
}
