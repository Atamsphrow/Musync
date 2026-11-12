// Tests du balayage karaoké : les spans d'une ligne mot à mot.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/ui/widgets/synced_lyrics_view.dart';

const sung = TextStyle(color: Colors.red, fontWeight: FontWeight.w700);
const unsung = TextStyle(color: Colors.grey, fontWeight: FontWeight.w400);

LyricLine line() => const LyricLine(
  timestamp: Duration(milliseconds: 10000),
  text: 'Une ligne ici',
  words: [
    LyricWord(
      start: Duration(milliseconds: 10000),
      duration: Duration(milliseconds: 500),
      text: 'Une',
    ),
    LyricWord(
      start: Duration(milliseconds: 10500),
      duration: Duration(milliseconds: 500),
      text: 'ligne',
    ),
    LyricWord(
      start: Duration(milliseconds: 11000),
      duration: Duration(milliseconds: 500),
      text: 'ici',
    ),
  ],
);

void main() {
  group('karaokeWordSpans', () {
    test('mot 0 : premier chanté, les autres non', () {
      final spans = karaokeWordSpans(
        line: line(),
        wordIndex: 0,
        sungStyle: sung,
        unsungStyle: unsung,
      );
      expect(spans.map((s) => s.text).join(), 'Une ligne ici');
      expect(spans[0].text, 'Une');
      expect(spans[0].style, sung);
      expect(spans[2].text, 'ligne');
      expect(spans[2].style, unsung);
      expect(spans[4].text, 'ici');
      expect(spans[4].style, unsung);
    });

    test('mot 1 : les deux premiers chantés', () {
      final spans = karaokeWordSpans(
        line: line(),
        wordIndex: 1,
        sungStyle: sung,
        unsungStyle: unsung,
      );
      expect(spans[0].style, sung);
      expect(spans[2].style, sung);
      expect(spans[4].style, unsung);
    });

    test('dernier mot : tout chanté', () {
      final spans = karaokeWordSpans(
        line: line(),
        wordIndex: 2,
        sungStyle: sung,
        unsungStyle: unsung,
      );
      expect(spans.every((s) => s.style == sung), isTrue);
    });

    test('les espaces séparent les mots', () {
      final spans = karaokeWordSpans(
        line: line(),
        wordIndex: 1,
        sungStyle: sung,
        unsungStyle: unsung,
      );
      expect(spans, hasLength(5));
      expect(spans[1].text, ' ');
      expect(spans[3].text, ' ');
    });
  });
}
