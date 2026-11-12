// Tests for word timings in the lyrics model (LyricWord / LyricLine.words).
//
// Words live in memory only: the file formats (SYLT/USLT/LRC) are
// line-level, so a round-trip through LRC drops them — that is
// documented here, not hidden.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';

const _words = [
  LyricWord(
    start: Duration(milliseconds: 1000),
    duration: Duration(milliseconds: 500),
    text: 'Une',
  ),
  LyricWord(
    start: Duration(milliseconds: 1500),
    duration: Duration(milliseconds: 500),
    text: 'ligne',
    isBackground: true,
  ),
];

void main() {
  group('LyricWord', () {
    test('égalité sur les quatre champs', () {
      const a = LyricWord(
        start: Duration(milliseconds: 1000),
        duration: Duration(milliseconds: 500),
        text: 'Une',
      );
      const b = LyricWord(
        start: Duration(milliseconds: 1000),
        duration: Duration(milliseconds: 500),
        text: 'Une',
      );
      const c = LyricWord(
        start: Duration(milliseconds: 1000),
        duration: Duration(milliseconds: 500),
        text: 'Une',
        isBackground: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('LyricLine.words', () {
    test('vide par défaut', () {
      const line = LyricLine(
        timestamp: Duration(seconds: 1),
        text: 'Une ligne',
      );
      expect(line.words, isEmpty);
      expect(line.hasWordTimings, isFalse);
    });

    test('copyWith garde les mots', () {
      const line = LyricLine(
        timestamp: Duration(seconds: 1),
        text: 'Une ligne',
        words: _words,
      );
      final moved = line.copyWith(
        timestamp: const Duration(milliseconds: 1100),
      );
      expect(moved.words, _words);
      expect(moved.hasWordTimings, isTrue);
      expect(line.timestamp, const Duration(seconds: 1));
    });

    test('withoutTimestamp garde les mots', () {
      const line = LyricLine(
        timestamp: Duration(seconds: 1),
        text: 'Une ligne',
        words: _words,
      );
      final untimed = line.withoutTimestamp();
      expect(untimed.timestamp, isNull);
      expect(untimed.words, _words);
    });

    test('égalité : mêmes lignes, mots différents = lignes différentes', () {
      const a = LyricLine(
        timestamp: Duration(seconds: 1),
        text: 'Une ligne',
        words: _words,
      );
      const b = LyricLine(timestamp: Duration(seconds: 1), text: 'Une ligne');
      expect(a, isNot(b));
    });
  });

  group('SyncedLyrics.hasWordTimings', () {
    test('vrai quand une ligne porte des mots', () {
      final lyrics = SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'Sans mots'),
        const LyricLine(
          timestamp: Duration(seconds: 2),
          text: 'Avec mots',
          words: _words,
        ),
      ]);
      expect(lyrics.hasWordTimings, isTrue);
    });

    test('faux sans mots', () {
      final lyrics = SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'Sans mots'),
      ]);
      expect(lyrics.hasWordTimings, isFalse);
    });

    test('le tri ignore les mots', () {
      final lyrics = SyncedLyrics([
        const LyricLine(
          timestamp: Duration(seconds: 2),
          text: 'Deux',
          words: _words,
        ),
        const LyricLine(timestamp: Duration(seconds: 1), text: 'Un'),
      ]);
      expect(lyrics.lines.map((l) => l.text), ['Un', 'Deux']);
    });

    test('toLrc ignore les mots', () {
      final lyrics = SyncedLyrics([
        const LyricLine(
          timestamp: Duration(seconds: 1),
          text: 'Une ligne',
          words: _words,
        ),
      ]);
      expect(lyrics.toLrc(), '[00:01.00]Une ligne');
    });

    test('aller-retour LRC : les mots ne survivent pas au fichier', () {
      final lyrics = SyncedLyrics([
        const LyricLine(
          timestamp: Duration(seconds: 1),
          text: 'Une ligne',
          words: _words,
        ),
      ]);
      final parsed = SyncedLyrics.fromLrc(lyrics.toLrc());
      expect(parsed.lines.single.text, 'Une ligne');
      expect(parsed.lines.single.words, isEmpty);
      expect(parsed.hasWordTimings, isFalse);
    });
  });
}
