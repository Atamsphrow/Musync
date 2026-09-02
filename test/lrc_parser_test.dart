// Tests for the LRC parser and the lyrics value objects.
//
// LRC has no specification anyone agrees on, so most of what is asserted here
// is tolerance: the files come from the internet, and a shape this parser
// refuses is a song the user can't sync.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';

void main() {
  group('LrcParser.parse — timestamp shapes', () {
    test('reads centiseconds', () {
      final lyrics = LrcParser.parse('[01:23.45]Bonjour');

      expect(lyrics.lines, hasLength(1));
      expect(
        lyrics.lines.first.timestamp,
        const Duration(minutes: 1, seconds: 23, milliseconds: 450),
      );
      expect(lyrics.lines.first.text, 'Bonjour');
    });

    test('reads milliseconds', () {
      final lyrics = LrcParser.parse('[00:05.123]Trois chiffres');

      expect(
        lyrics.lines.first.timestamp,
        const Duration(seconds: 5, milliseconds: 123),
      );
    });

    test('accepts a timestamp with no fraction at all', () {
      // The old regex required one, so `[00:12]Texte` was dropped silently.
      final lyrics = LrcParser.parse('[00:12]Sans fraction');

      expect(lyrics.lines.first.timestamp, const Duration(seconds: 12));
      expect(lyrics.lines.first.text, 'Sans fraction');
    });

    test('accepts a colon as the fraction separator', () {
      final lyrics = LrcParser.parse('[00:12:50]Deux-points');

      expect(
        lyrics.lines.first.timestamp,
        const Duration(seconds: 12, milliseconds: 500),
      );
    });

    test('reads timestamps past ten minutes', () {
      final lyrics = LrcParser.parse('[123:45.67]Morceau très long');

      expect(
        lyrics.lines.first.timestamp,
        const Duration(minutes: 123, seconds: 45, milliseconds: 670),
      );
    });
  });

  group('LrcParser.parse — structure', () {
    test('repeats the text once per leading timestamp', () {
      // How a repeated chorus is written.
      final lyrics = LrcParser.parse('[00:10.00][01:20.00][02:30.00]Refrain');

      expect(lyrics.lines, hasLength(3));
      expect(lyrics.lines.map((l) => l.text), everyElement('Refrain'));
      expect(lyrics.lines.map((l) => l.timestamp!.inSeconds), [10, 80, 150]);
    });

    test('drops metadata rows', () {
      final lyrics = LrcParser.parse('''
[ar:Artiste]
[ti:Titre]
[length:03:21]
[00:01.00]Première
''');

      expect(lyrics.lines, hasLength(1));
      expect(lyrics.lines.first.text, 'Première');
    });

    test('applies [offset:] instead of ignoring it', () {
      // Positive offset means the lyrics should land earlier.
      final lyrics = LrcParser.parse('''
[offset:+500]
[00:10.00]Décalée
''');

      expect(
        lyrics.lines.first.timestamp,
        const Duration(seconds: 9, milliseconds: 500),
      );
    });

    test('a negative offset never pushes a line before zero', () {
      final lyrics = LrcParser.parse('''
[offset:5000]
[00:01.00]Au début
''');

      expect(lyrics.lines.first.timestamp, Duration.zero);
    });

    test('keeps empty lines, which mark instrumental breaks', () {
      final lyrics = LrcParser.parse('''
[00:01.00]Couplet
[00:30.00]
[00:45.00]Suite
''');

      expect(lyrics.lines, hasLength(3));
      expect(lyrics.lines[1].text, isEmpty);
    });

    test('ignores rows with no timestamp', () {
      final lyrics = LrcParser.parse('''
Une note de bas de page
[00:01.00]Vraie ligne
''');

      expect(lyrics.lines, hasLength(1));
    });

    test('a bracketed aside inside a lyric stays part of the text', () {
      // Only the leading run counts. Consuming the second bracket would drop
      // "Le refrain" from the line entirely.
      final lyrics = LrcParser.parse('[00:01.00]Le refrain [00:02.00] chanté');

      expect(lyrics.lines, hasLength(1));
      expect(lyrics.lines.first.text, 'Le refrain [00:02.00] chanté');
    });

    test('an empty document yields empty lyrics rather than throwing', () {
      expect(LrcParser.parse('').isEmpty, isTrue);
      expect(LrcParser.parse('\n\n\n').isEmpty, isTrue);
    });
  });

  group('LrcParser.generate', () {
    test('round-trips through parse', () {
      final original = SyncedLyrics([
        const LyricLine(timestamp: Duration.zero, text: 'Zéro'),
        const LyricLine(
          timestamp: Duration(minutes: 1, seconds: 2, milliseconds: 340),
          text: 'Un peu plus tard',
        ),
      ]);

      expect(LrcParser.parse(original.toLrc()).lines, original.lines);
    });

    test('pads every field to two digits', () {
      expect(
        LrcParser.formatTimestamp(
          const Duration(minutes: 1, seconds: 2, milliseconds: 30),
        ),
        '01:02.03',
      );
    });
  });

  group('SyncedLyrics', () {
    final sample = SyncedLyrics([
      const LyricLine(timestamp: Duration(seconds: 30), text: 'Troisième'),
      const LyricLine(timestamp: Duration(seconds: 10), text: 'Première'),
      const LyricLine(timestamp: Duration(seconds: 20), text: 'Deuxième'),
    ]);

    test('sorts by timestamp on construction', () {
      expect(sample.lines.map((l) => l.text), [
        'Première',
        'Deuxième',
        'Troisième',
      ]);
    });

    test('the sort is stable, so untimed lines keep their reading order', () {
      // Every line at zero is what the editor starts from when a file has only
      // plain lyrics; an unstable sort would scramble the verse.
      final untimed = SyncedLyrics([
        for (final text in ['un', 'deux', 'trois', 'quatre', 'cinq'])
          LyricLine(timestamp: Duration.zero, text: text),
      ]);

      expect(untimed.lines.map((l) => l.text), [
        'un',
        'deux',
        'trois',
        'quatre',
        'cinq',
      ]);
    });

    test('getLineAt finds the line in progress', () {
      expect(sample.getLineAt(const Duration(seconds: 25)), 1);
      expect(sample.getLineAt(const Duration(seconds: 20)), 1);
      expect(sample.getLineAt(const Duration(minutes: 5)), 2);
    });

    test('getLineAt returns null before the first line', () {
      expect(sample.getLineAt(const Duration(seconds: 5)), isNull);
      expect(SyncedLyrics.empty().getLineAt(Duration.zero), isNull);
    });

    test('offsetAll shifts every line', () {
      final shifted = sample.offsetAll(const Duration(seconds: 5));

      expect(shifted.lines.map((l) => l.timestamp!.inSeconds), [15, 25, 35]);
    });

    test('offsetAll floors at zero instead of going negative', () {
      final shifted = sample.offsetAll(const Duration(seconds: -15));

      expect(shifted.lines.first.timestamp, Duration.zero);
    });

    test('offsetLine touches only the line asked for', () {
      final shifted = sample.offsetLine(0, const Duration(seconds: 2));

      expect(shifted.lines.map((l) => l.timestamp!.inSeconds), [12, 20, 30]);
    });

    test('offsetLine ignores an out-of-range index', () {
      expect(sample.offsetLine(99, const Duration(seconds: 1)), sample);
    });

    test('equality is by value — it is used as a provider key', () {
      final a = SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'a'),
      ]);
      final b = SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'a'),
      ]);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differing lyrics are not equal', () {
      final a = SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'a'),
      ]);
      final b = SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 2), text: 'a'),
      ]);

      expect(a, isNot(b));
    });

    test('toPlainText flattens to one line per lyric', () {
      expect(sample.toPlainText(), 'Première\nDeuxième\nTroisième');
    });
  });

  group('UnsyncedLyrics', () {
    test('whitespace-only text counts as empty', () {
      expect(const UnsyncedLyrics('   \n  ').isEmpty, isTrue);
      expect(const UnsyncedLyrics('paroles').isNotEmpty, isTrue);
    });

    test('equality is by value', () {
      expect(const UnsyncedLyrics('a'), const UnsyncedLyrics('a'));
      expect(const UnsyncedLyrics('a'), isNot(const UnsyncedLyrics('b')));
    });
  });

  group('stripTimestamps', () {
    // Turns an LRC-bearing USLT into words. Distinct from parse(), which keeps
    // only the timed lines — here nothing may be dropped.
    test('removes the prefixes and keeps the words', () {
      expect(
        LrcParser.stripTimestamps('[00:01.00]Une\n[00:04.50]Deux'),
        'Une\nDeux',
      );
    });

    test('keeps a line that never had a timestamp', () {
      // The whole reason this is not `parse().toPlainText()`: a structural
      // marker belongs to the lyric and would be filtered out by parsing.
      expect(
        LrcParser.stripTimestamps('[00:01.00]Une\n[Refrain]\n[00:09.00]Deux'),
        'Une\n[Refrain]\nDeux',
      );
    });

    test('strips a whole run of prefixes, as a repeated chorus carries', () {
      expect(
        LrcParser.stripTimestamps('[00:10.00][01:20.00][02:30.00]Refrain'),
        'Refrain',
      );
    });

    test('leaves a timestamp that is not at the head of the line', () {
      // Mid-sentence brackets are lyrics, not cues — the same call the parser
      // makes. The two must agree on where the words begin.
      expect(
        LrcParser.stripTimestamps('[00:01.00]On se voit a [00:02.00] pile'),
        'On se voit a [00:02.00] pile',
      );
    });

    test('text with no timestamps at all comes back unchanged', () {
      expect(
        LrcParser.stripTimestamps('Une chanson\nsans horodatage'),
        'Une chanson\nsans horodatage',
      );
    });
  });

  group('timestamps separated by a space', () {
    test('a chorus written with spaces keeps both timings', () {
      // A shape that turns up in downloaded files. `parse` required the
      // timestamps to be adjacent, so it took the first, left the second
      // bracket sitting in the words, and lost one of the two cues.
      final lyrics = LrcParser.parse('[00:10.00] [01:20.00]Refrain');

      expect(lyrics.length, 2);
      expect(lyrics.lines.map((l) => l.text), ['Refrain', 'Refrain']);
      expect(lyrics.lines.first.timestamp, const Duration(seconds: 10));
      expect(lyrics.lines.last.timestamp, const Duration(seconds: 80));
    });

    test('and no bracket is left in the words', () {
      final lyrics = LrcParser.parse('[00:01.00]  [00:05.00]Texte');

      expect(lyrics.lines.first.text, 'Texte');
      expect(lyrics.lines.first.text, isNot(contains('[')));
    });

    test('parse and stripTimestamps agree on where the words start', () {
      // They disagreed: stripping allowed the space, parsing did not, so the
      // same line came out two different ways depending on which one saw it.
      const line = '[00:01.00] [00:05.00]Texte';

      expect(LrcParser.stripTimestamps(line), 'Texte');
      expect(LrcParser.parse(line).lines.first.text, 'Texte');
    });

    test('a timestamp after real words is still a lyric', () {
      // The distinction that must survive: only the *leading* run is cues.
      final lyrics = LrcParser.parse('[00:01.00]Il a dit [00:05.00] puis rien');

      expect(lyrics.length, 1);
      expect(lyrics.lines.single.text, 'Il a dit [00:05.00] puis rien');
    });

    test('a line that opens with words is not timed at all', () {
      expect(LrcParser.parse('Sans heure [00:05.00]').isEmpty, isTrue);
    });
  });
}
