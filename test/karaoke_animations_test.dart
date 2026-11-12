import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/ui/widgets/karaoke_animated_line.dart';
import 'package:musync/features/player/ui/widgets/karaoke_math.dart';

LyricWord _word(String text, int startMs, int durationMs) => LyricWord(
  start: Duration(milliseconds: startMs),
  duration: Duration(milliseconds: durationMs),
  text: text,
);

LyricLine _line(List<LyricWord> words) => LyricLine(
  timestamp: Duration.zero,
  text: words.map((w) => w.text).join(' '),
  words: words,
);

const _sung = TextStyle(
  fontSize: 16,
  color: Colors.white,
  fontWeight: FontWeight.w700,
);
const _unsung = TextStyle(
  fontSize: 16,
  color: Colors.grey,
  fontWeight: FontWeight.w400,
);

void main() {
  group('smoothstep', () {
    test('0, 0.5 and 1 are fixed points, outside is clamped', () {
      expect(smoothstep(0), 0.0);
      expect(smoothstep(0.5), closeTo(0.5, 0.001));
      expect(smoothstep(1), 1.0);
      expect(smoothstep(-2), 0.0);
      expect(smoothstep(3), 1.0);
    });
  });

  group('liftHeightFraction', () {
    test('a word sung in 150 ms or less only nudges', () {
      expect(liftHeightFraction(_word('oh', 0, 90)), 0.25);
      expect(liftHeightFraction(_word('oh', 0, 150)), 0.25);
    });

    test('a word held 900 ms or more goes all the way up', () {
      expect(liftHeightFraction(_word('love', 0, 900)), 1.0);
      expect(liftHeightFraction(_word('love', 0, 3000)), 1.0);
    });

    test('halfway in time is halfway in height', () {
      expect(
        liftHeightFraction(_word('love', 0, 525)),
        closeTo(0.625, 0.001),
      );
    });
  });

  group('wordLiftFraction', () {
    test('zero before the word starts', () {
      final word = _word('love', 1000, 1000);
      expect(
        wordLiftFraction(word: word, position: const Duration(milliseconds: 999)),
        0.0,
      );
    });

    test('rises over its own length, then settles over 700 ms', () {
      final word = _word('love', 1000, 1000);
      // Halfway through: rising 500/700, falling 1 — lift is the
      // smoothstep of the smaller one, times the full height.
      expect(
        wordLiftFraction(word: word, position: const Duration(milliseconds: 1500)),
        closeTo(0.80, 0.02),
      );
      // 350 ms past the end: falling is 0.5.
      expect(
        wordLiftFraction(word: word, position: const Duration(milliseconds: 2350)),
        closeTo(0.5, 0.01),
      );
      // 700 ms past the end: back on the floor.
      expect(
        wordLiftFraction(word: word, position: const Duration(milliseconds: 2700)),
        0.0,
      );
    });

    test('a quick word rises slowly and barely lifts', () {
      final word = _word('oh', 1000, 90);
      expect(
        wordLiftFraction(word: word, position: const Duration(milliseconds: 1045)),
        closeTo(0.021, 0.005),
      );
    });
  });

  group('wordSweepFraction', () {
    test('0 before, linear across, 1 after', () {
      final word = _word('love', 1000, 1000);
      expect(
        wordSweepFraction(word: word, position: const Duration(milliseconds: 500)),
        0.0,
      );
      expect(
        wordSweepFraction(word: word, position: const Duration(milliseconds: 1500)),
        0.5,
      );
      expect(
        wordSweepFraction(word: word, position: const Duration(milliseconds: 2500)),
        1.0,
      );
    });
  });

  group('canGrowWord', () {
    test('thresholds by length', () {
      expect(canGrowWord(_word('a', 0, 1100)), isTrue);
      expect(canGrowWord(_word('a', 0, 1099)), isFalse);
      expect(canGrowWord(_word('ab', 0, 1360)), isTrue);
      expect(canGrowWord(_word('ab', 0, 1359)), isFalse);
      expect(canGrowWord(_word('abc', 0, 1500)), isTrue);
      expect(canGrowWord(_word('abc', 0, 1499)), isFalse);
      expect(canGrowWord(_word('abcd', 0, 1050)), isTrue);
      expect(canGrowWord(_word('abcd', 0, 1049)), isFalse);
      // Five letters: 900 ms and 200 ms a letter.
      expect(canGrowWord(_word('abcde', 0, 1000)), isTrue);
      expect(canGrowWord(_word('abcde', 0, 999)), isFalse);
      expect(canGrowWord(_word('abcdefg', 0, 1400)), isTrue);
      expect(canGrowWord(_word('abcdefg', 0, 1399)), isFalse);
    });

    test('more than seven letters never grows', () {
      expect(canGrowWord(_word('abcdefgh', 0, 5000)), isFalse);
    });

    test('hyphenated words and block or joined scripts are left alone', () {
      expect(canGrowWord(_word('well-known', 0, 5000)), isFalse);
      expect(canGrowWord(_word('爱', 0, 5000)), isFalse);
      expect(canGrowWord(_word('あい', 0, 5000)), isFalse);
      expect(canGrowWord(_word('사랑', 0, 5000)), isFalse);
      expect(canGrowWord(_word('حب', 0, 5000)), isFalse);
    });
  });

  group('growingWordRestsAt', () {
    test('last letter rests after its stagger plus the span', () {
      final word = _word('love', 1000, 2000);
      // (4 - 1) * 0.09 + 1.5 = 1.77 spans of the word's length.
      expect(growingWordRestsAt(word), const Duration(milliseconds: 4540));
    });
  });

  group('growingLetter', () {
    test('at rest before the word starts', () {
      final word = _word('love', 1000, 3000);
      final at = growingLetter(
        word: word,
        charIndex: 0,
        position: const Duration(milliseconds: 1000),
      );
      expect(at.scale, 1.0);
      expect(at.bloom, 0.0);
      expect(at.rise, 0.0);
    });

    test('a long-held word swells and glows mid-word', () {
      final word = _word('love', 0, 3000);
      final at = growingLetter(
        word: word,
        charIndex: 0,
        position: const Duration(milliseconds: 1500),
      );
      // Near its peak: scale ~1.10, bloom ~0.87.
      expect(at.scale, closeTo(1.10, 0.01));
      expect(at.bloom, closeTo(0.87, 0.03));
    });

    test('the wave travels along the word: the first letter leads', () {
      final word = _word('love', 0, 3000);
      const position = Duration(milliseconds: 750);
      final first = growingLetter(word: word, charIndex: 0, position: position);
      final second = growingLetter(word: word, charIndex: 1, position: position);
      expect(first.scale, greaterThan(second.scale));
      expect(first.bloom, greaterThan(second.bloom));
    });

    test('at rest after the last letter settles', () {
      final word = _word('love', 0, 3000);
      final at = growingLetter(
        word: word,
        charIndex: 3,
        position: const Duration(milliseconds: 6000),
      );
      expect(at.scale, 1.0);
      expect(at.bloom, 0.0);
      expect(at.rise, 1.0);
    });
  });

  group('animatedKaraokeSpans', () {
    test('before the first word: plain spans, nothing animated', () {
      final line = _line([
        _word('love', 1000, 500),
        _word('you', 1600, 500),
      ]);
      final spans = animatedKaraokeSpans(
        line: line,
        wordIndex: -1,
        position: const Duration(milliseconds: 500),
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      expect(spans.every((s) => s is TextSpan), isTrue);
      expect((spans[0] as TextSpan).style, _unsung);
    });

    test('the word being sung is a swept WidgetSpan, the rest plain', () {
      final line = _line([
        _word('love', 1000, 1000),
        _word('you', 2100, 500),
      ]);
      final spans = animatedKaraokeSpans(
        line: line,
        wordIndex: 0,
        position: const Duration(milliseconds: 1500),
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      expect(spans[0], isA<WidgetSpan>());
      expect(spans[1], isA<TextSpan>());
      expect((spans[2] as TextSpan).style, _unsung);
    });

    test('a word that just ended is still a lifted WidgetSpan', () {
      final line = _line([
        _word('love', 1000, 500),
        _word('you', 1600, 500),
      ]);
      final spans = animatedKaraokeSpans(
        line: line,
        wordIndex: 1,
        position: const Duration(milliseconds: 1700),
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      // The first word ended 200 ms ago: still settling, so a widget.
      expect(spans[0], isA<WidgetSpan>());
      // The current word, mid-sweep: a widget too.
      expect(spans[2], isA<WidgetSpan>());
    });

    test('a held word grows letter by letter in a Text.rich widget', () {
      final line = _line([_word('love', 1000, 3000)]);
      final spans = animatedKaraokeSpans(
        line: line,
        wordIndex: 0,
        position: const Duration(milliseconds: 2000),
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      expect(spans[0], isA<WidgetSpan>());
      final widget = (spans[0] as WidgetSpan).child;
      expect(widget, isA<GestureDetector>());
      final translated = (widget as GestureDetector).child;
      expect(translated, isA<Transform>());
      final inner = (translated as Transform).child;
      expect(inner, isA<Text>());
      final textSpan = (inner as Text).textSpan as TextSpan;
      expect(textSpan.children?.length, 4);
    });
  });
}
