// Tests du balayage karaoké : les spans d'une ligne mot à mot.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/ui/widgets/synced_lyrics_view.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';

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

    test('mot de fond : atténué et italique, chanté ou non', () {
      const backgroundLine = LyricLine(
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
            isBackground: true,
          ),
          LyricWord(
            start: Duration(milliseconds: 11000),
            duration: Duration(milliseconds: 500),
            text: 'ici',
            isBackground: true,
          ),
        ],
      );
      final spans = karaokeWordSpans(
        line: backgroundLine,
        wordIndex: 1,
        sungStyle: sung,
        unsungStyle: unsung,
      );
      // Le mot de tête garde son style plein.
      expect(spans[0].style, sung);
      // Les mots de fond : même base, atténuée et italique.
      expect(spans[2].style?.fontStyle, FontStyle.italic);
      expect(spans[2].style?.color, sung.color?.withValues(alpha: 0.6));
      expect(spans[4].style?.fontStyle, FontStyle.italic);
      expect(spans[4].style?.color, unsung.color?.withValues(alpha: 0.6));
    });
  });

  group('tap sur un mot', () {
    test('chaque mot cherche à son début', () {
      final tapped = <Duration>[];
      final spans = karaokeWordSpans(
        line: line(),
        wordIndex: 0,
        sungStyle: sung,
        unsungStyle: unsung,
        onWordTap: tapped.add,
      );
      (spans[0].recognizer as TapGestureRecognizer).onTap!();
      (spans[2].recognizer as TapGestureRecognizer).onTap!();
      (spans[4].recognizer as TapGestureRecognizer).onTap!();
      expect(tapped, [
        const Duration(milliseconds: 10000),
        const Duration(milliseconds: 10500),
        const Duration(milliseconds: 11000),
      ]);
    });

    test('tap entre deux mots : début du mot d’avant', () {
      final tapped = <Duration>[];
      final spans = karaokeWordSpans(
        line: line(),
        wordIndex: 1,
        sungStyle: sung,
        unsungStyle: unsung,
        onWordTap: tapped.add,
      );
      (spans[1].recognizer as TapGestureRecognizer).onTap!();
      (spans[3].recognizer as TapGestureRecognizer).onTap!();
      expect(tapped, [
        const Duration(milliseconds: 10000),
        const Duration(milliseconds: 10500),
      ]);
    });

    test('sans onWordTap : aucun recognizer', () {
      final spans = karaokeWordSpans(
        line: line(),
        wordIndex: 0,
        sungStyle: sung,
        unsungStyle: unsung,
      );
      expect(spans.every((s) => s.recognizer == null), isTrue);
    });

    test('wordIndex -1 : aucun mot chanté', () {
      final spans = karaokeWordSpans(
        line: line(),
        wordIndex: -1,
        sungStyle: sung,
        unsungStyle: unsung,
      );
      expect(spans.every((s) => s.style == unsung), isTrue);
    });
  });

  group('romanizationSpan', () {
    const appearance = LyricsAppearance();
    const dim = Color(0x8AFFFFFF);

    test('ligne avec romanisation différente : span italique', () {
      const line = LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: '夜空中最亮的星',
        romanization: 'yè kōng zhōng zuì liàng de xīng',
      );
      final span = romanizationSpan(line, appearance, dim);
      expect(span, isNotNull);
      expect(span!.text, contains('yè kōng'));
      expect(span.style?.fontStyle, FontStyle.italic);
    });

    test('romanisation identique à la ligne : rien', () {
      const line = LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: 'Ooh, ooh, woah',
        romanization: 'Ooh, ooh, woah',
      );
      expect(romanizationSpan(line, appearance, dim), isNull);
    });

    test('réglage coupé : rien', () {
      const line = LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: '夜空中最亮的星',
        romanization: 'yè kōng zhōng zuì liàng de xīng',
      );
      expect(
        romanizationSpan(
          line,
          appearance.copyWith(showRomanization: false),
          dim,
        ),
        isNull,
      );
    });

    test('pas de romanisation : rien', () {
      const line = LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: 'Une ligne ici',
      );
      expect(romanizationSpan(line, appearance, dim), isNull);
    });
  });

  group('LyricLine.romanization', () {
    test('copyWith garde la romanisation, == la compare', () {
      const line = LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: '夜空中最亮的星',
        romanization: 'yè kōng zhōng zuì liàng de xīng',
      );
      expect(line.copyWith(text: 'Autre').romanization, line.romanization);
      expect(
        line,
        isNot(const LyricLine(
          timestamp: Duration(milliseconds: 1000),
          text: '夜空中最亮的星',
        )),
      );
      expect(
        line.hashCode,
        isNot(const LyricLine(
          timestamp: Duration(milliseconds: 1000),
          text: '夜空中最亮的星',
        ).hashCode),
      );
    });
  });

  group('voicePrefix', () {
    test('duo : seule la deuxième voix est marquée', () {
      const v1 = LyricLine(
        timestamp: Duration(milliseconds: 0),
        text: 'Premier couplet',
        voice: 1,
      );
      const v2 = LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: 'Réponse',
        voice: 2,
      );
      const together = LyricLine(
        timestamp: Duration(milliseconds: 2000),
        text: 'Refrain',
        voice: 0,
      );
      expect(voicePrefix(v1, true), isNull);
      expect(voicePrefix(v2, true), 'V2');
      expect(voicePrefix(together, true), isNull);
    });

    test('pas un duo : rien n’est marqué', () {
      const v2 = LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: 'Réponse',
        voice: 2,
      );
      expect(voicePrefix(v2, false), isNull);
    });
  });

  group('LyricLine.voice', () {
    test('copyWith garde la voix, == la compare', () {
      const line = LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: 'Réponse',
        voice: 2,
      );
      expect(line.copyWith(text: 'Autre').voice, 2);
      expect(line, isNot(const LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: 'Réponse',
        voice: 1,
      )));
      expect(line.hashCode, isNot(const LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: 'Réponse',
      ).hashCode));
    });

    test('hasDuet : deux voix distinctes, sinon non', () {
      final duet = SyncedLyrics([
        const LyricLine(
          timestamp: Duration(milliseconds: 0),
          text: 'Un',
          voice: 1,
        ),
        const LyricLine(
          timestamp: Duration(milliseconds: 1000),
          text: 'Deux',
          voice: 2,
        ),
      ]);
      expect(duet.hasDuet, isTrue);
      final solo = SyncedLyrics([
        const LyricLine(
          timestamp: Duration(milliseconds: 0),
          text: 'Un',
          voice: 1,
        ),
        const LyricLine(
          timestamp: Duration(milliseconds: 1000),
          text: 'Deux',
          voice: 1,
        ),
      ]);
      expect(solo.hasDuet, isFalse);
      final together = SyncedLyrics([
        const LyricLine(
          timestamp: Duration(milliseconds: 0),
          text: 'Un',
          voice: 0,
        ),
        const LyricLine(
          timestamp: Duration(milliseconds: 1000),
          text: 'Deux',
          voice: 2,
        ),
      ]);
      expect(together.hasDuet, isFalse);
      final unknown = SyncedLyrics([
        const LyricLine(timestamp: Duration(milliseconds: 0), text: 'Un'),
        const LyricLine(timestamp: Duration(milliseconds: 1000), text: 'Deux'),
      ]);
      expect(unknown.hasDuet, isFalse);
    });
  });
}
