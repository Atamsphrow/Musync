/// The words the karaoke view lights, one real word at a time.
///
/// Two problems, one pass over the lyrics, display-side only — the file and
/// the word store are never touched:
///
/// * **Coarse timing units.** Some sources time a group of words as one
///   unit (« Hello world »), or carry the space inside the unit
///   (« Hello  » then « world »), which glued every word of the line into a
///   single karaoke unit. On a line that wraps, that unit was one box swept
///   left to right across both visual lines at once — half of each lit, in
///   no relation to what was being sung. Such a unit is split here into its
///   words, each with its share of the unit's time.
/// * **Line-only lyrics.** Most lyrics are timed per line (LRCLIB, the file,
///   the editor). With [prepareKaraokeWords]' `estimateUntimed`, each such
///   line gets estimated word timings, spread over the time it is sung, so
///   every song can be followed word by word.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:musync/core/id3/models/lyrics.dart';

/// True for the letters of scripts written without spaces between words —
/// Han and kana. Each such character is its own karaoke unit: there is no
/// word boundary to find, and a whole line glued into one unit is exactly
/// the bug this file fixes. Hangul is written with spaces, so it is not here.
bool isUnspacedScriptRune(int rune) {
  // Han: CJK unified ideographs, extension A, compatibility, extensions B+.
  if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
  if (rune >= 0x3400 && rune <= 0x4DBF) return true;
  if (rune >= 0xF900 && rune <= 0xFAFF) return true;
  if (rune >= 0x20000 && rune <= 0x2FFFF) return true;
  // Hiragana and katakana letters (the voicing and length marks are not
  // letters of their own — see [_attachesToPrevious]).
  if (rune >= 0x3041 && rune <= 0x3096) return true;
  if (rune >= 0x30A1 && rune <= 0x30FA) return true;
  if (rune >= 0x31F0 && rune <= 0x31FF) return true;
  // Half-width katakana.
  if (rune >= 0xFF66 && rune <= 0xFF9D) return true;
  return false;
}

/// Opening punctuation: it belongs to the word after it.
const Set<int> _openers = {
  0x28, 0x5B, 0x7B, 0xAB, 0xBF, 0xA1, 0x201C, 0x2018, // ( [ { « ¿ ¡ “ ‘
  0x300C, 0x300E, 0xFF08, 0x3010, 0x3008, 0x300A, 0x3014, 0xFF3B, 0xFF5B,
  0x3016, // 「 『 （ 【 〈 《 〔 ［ ｛ 〖
};

/// Closing punctuation and marks that are part of the character before
/// them: they belong to the word before.
bool _attachesToPrevious(int rune) {
  const closers = {
    0x29, 0x5D, 0x7D, 0xBB, 0x201D, 0x2019, 0x2C, 0x2E, 0x21, 0x3F, 0x3B,
    0x3A, 0x2026, // ) ] } » ” ’ , . ! ? ; : …
    0x3001, 0x3002, 0x300D, 0x300F, 0xFF09, 0x3011, 0x3009, 0x300B, 0x3015,
    0xFF3D, 0xFF5D, 0x3017, // 、 。 」 』 ） 】 〉 》 〕 ］ ｝ 〗
    0xFF0C, 0xFF0E, 0xFF01, 0xFF1F, 0xFF1B, 0xFF1A, 0xFF5E, 0x301C,
    0x30FB, // ， ． ！ ？ ； ： ～ 〜 ・
  };
  if (closers.contains(rune)) return true;
  // Kana voicing marks (combining and spacing), the length mark ー, the
  // iteration marks, and the half-width voicing marks.
  if (rune >= 0x3099 && rune <= 0x309E) return true;
  if (rune >= 0x30FC && rune <= 0x30FE) return true;
  if (rune == 0xFF70 || rune == 0xFF9E || rune == 0xFF9F) return true;
  return false;
}

/// Splits [text] into karaoke words, in order: runs of characters between
/// spaces, except that each Han or kana character is a word of its own.
/// Punctuation stays with its word — an opening mark with the word after
/// it, a closing one with the word before — so a comma never lights alone.
///
/// The words are substrings of [text], in order, with only whitespace
/// dropped between them: joined back with the text's own spaces, they
/// cover it exactly — the condition the karaoke view checks before it
/// renders a line word by word.
@visibleForTesting
List<String> karaokeTokens(String text) {
  final tokens = <String>[];
  final current = StringBuffer();
  // True while [current] holds only opening punctuation, waiting for the
  // word it opens.
  var currentIsOpeners = false;
  // True when nothing but the last token's own characters stands between
  // it and the next character — a closing mark may still join it.
  var adjacent = false;

  void flush() {
    if (current.isEmpty) return;
    tokens.add(current.toString());
    current.clear();
    currentIsOpeners = false;
    adjacent = true;
  }

  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (char.trim().isEmpty) {
      flush();
      adjacent = false;
    } else if (_openers.contains(rune)) {
      if (current.isEmpty) currentIsOpeners = true;
      current.write(char);
    } else if (_attachesToPrevious(rune)) {
      if (current.isNotEmpty) {
        current.write(char);
        currentIsOpeners = false;
      } else if (adjacent && tokens.isNotEmpty) {
        tokens[tokens.length - 1] = tokens.last + char;
      } else {
        current.write(char);
      }
    } else if (isUnspacedScriptRune(rune)) {
      if (current.isNotEmpty && currentIsOpeners) {
        current.write(char);
        currentIsOpeners = false;
      } else {
        flush();
        current.write(char);
      }
      flush();
    } else {
      currentIsOpeners = false;
      current.write(char);
    }
  }
  flush();
  return tokens;
}

/// How much singing time a word takes, relative to the others: its
/// letters plus one for the move to the next word, and a syllable's worth
/// (three letters) for each Han or kana character, which is one syllable.
double _weight(String token) {
  var weight = 1.0;
  for (final rune in token.runes) {
    weight += isUnspacedScriptRune(rune) ? 3 : 1;
  }
  return weight;
}

/// [tokens] spread over [start]..[start] + [span], each in proportion to its
/// [_weight]. Back to back, and the last one ends exactly at the end of the
/// span — the rounding never loses or adds time.
List<LyricWord> _spread(
  List<String> tokens,
  Duration start,
  Duration span, {
  bool isBackground = false,
}) {
  final weights = [for (final token in tokens) _weight(token)];
  final total = weights.fold<double>(0, (sum, w) => sum + w);
  final spanUs = span.inMicroseconds;
  final words = <LyricWord>[];
  var acc = 0.0;
  var previousUs = 0;
  for (var i = 0; i < tokens.length; i++) {
    acc += weights[i];
    final endUs = i == tokens.length - 1
        ? spanUs
        : (spanUs * acc / total).round();
    words.add(
      LyricWord(
        start: start + Duration(microseconds: previousUs),
        duration: Duration(microseconds: endUs - previousUs),
        text: tokens[i],
        isBackground: isBackground,
      ),
    );
    previousUs = endUs;
  }
  return words;
}

/// Share of the time to the next line that the estimated words fill: the
/// rest is the breath before the next line.
const double kEstimatedWordsGapShare = 0.9;

/// Singing time per unit of [_weight] for an estimated line, when the next
/// line is far off (an instrumental break after it, or none at all): about
/// the pace of an ordinary sung line. The time to the next line caps it,
/// so fast lines keep up.
const Duration kEstimatedTimePerWeight = Duration(milliseconds: 130);

/// The shortest an estimated line lasts, so a two-word line does not flash.
const Duration kEstimatedMinLineTime = Duration(milliseconds: 1000);

/// The time [tokens] are sung over, starting at [start], when the next line
/// starts at [next] (null: none).
Duration _estimatedSpan(List<String> tokens, Duration start, Duration? next) {
  final total = tokens.fold<double>(0, (sum, t) => sum + _weight(t));
  final paceUs = math.max(
    kEstimatedMinLineTime.inMicroseconds,
    (kEstimatedTimePerWeight.inMicroseconds * total).round(),
  );
  if (next == null) return Duration(microseconds: paceUs);
  final gapUs = ((next - start).inMicroseconds * kEstimatedWordsGapShare)
      .round();
  return Duration(microseconds: math.max(1, math.min(paceUs, gapUs)));
}

/// [synced] with every line ready to light word by word.
///
/// * A word timing that holds several words — or a space — is split into
///   its words, each with its share of the time (in proportion to its
///   length), so words light in the order they are sung, one at a time.
///   A word without any space comes through untouched, syllable pieces
///   (« nev » + « er ») included.
/// * With [estimateUntimed], a line without word timings — or with
///   timings that do not match its text — gets estimated ones: its words
///   spread over the time it is sung, from its timestamp to just before
///   the next line (see [kEstimatedWordsGapShare]), at most at an ordinary
///   singing pace (see [kEstimatedTimePerWeight]).
///
/// Line count, order, timestamps and texts never change — only `words` —
/// so a line index means the same line in [synced] and in the result.
/// Returns [synced] itself when nothing changes.
SyncedLyrics prepareKaraokeWords(
  SyncedLyrics synced, {
  required bool estimateUntimed,
}) {
  final lines = synced.lines;
  var changed = false;
  final prepared = <LyricLine>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    var words = line.words;
    if (words.isNotEmpty) {
      words = _splitWords(words);
    }
    if (estimateUntimed && !_coversText(line.text, words)) {
      final tokens = karaokeTokens(line.text);
      if (tokens.isNotEmpty) {
        words = _estimate(lines, i, tokens);
      }
    }
    if (identical(words, line.words)) {
      prepared.add(line);
    } else {
      changed = true;
      prepared.add(line.copyWith(words: List.unmodifiable(words)));
    }
  }
  return changed ? SyncedLyrics(prepared) : synced;
}

/// [words] with every multi-word (or space-carrying) unit split into its
/// words; the same list when there is nothing to split.
List<LyricWord> _splitWords(List<LyricWord> words) {
  List<LyricWord>? split;
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    final tokens = karaokeTokens(word.text);
    final unchanged = tokens.length == 1 && tokens.single == word.text;
    if (unchanged) {
      split?.add(word);
      continue;
    }
    split ??= [...words.take(i)];
    if (tokens.isEmpty) continue;
    split.addAll(
      _spread(
        tokens,
        word.start,
        word.duration,
        isBackground: word.isBackground,
      ),
    );
  }
  return split ?? words;
}

/// Whether [words] cover [text] exactly, spaces aside — the same rule as
/// the view's `karaokeWordSeparators`, which falls back to the plain line
/// when it fails.
bool _coversText(String text, List<LyricWord> words) {
  if (words.isEmpty) return false;
  var pos = 0;
  bool isSpace(int i) => text[i].trim().isEmpty;
  for (final word in words) {
    while (pos < text.length && isSpace(pos)) {
      pos++;
    }
    if (word.text.isEmpty || !text.startsWith(word.text, pos)) return false;
    pos += word.text.length;
  }
  while (pos < text.length && isSpace(pos)) {
    pos++;
  }
  return pos == text.length;
}

/// Estimated words for line [index]. A line that had word timings which do
/// not match its text keeps their time span; a line-only one is sung from
/// its timestamp towards the next line's.
List<LyricWord> _estimate(List<LyricLine> lines, int index, List<String> tokens) {
  final line = lines[index];
  final start = line.timestamp!;
  final words = line.words;
  if (words.isNotEmpty) {
    final first = words.map((w) => w.start).reduce((a, b) => a < b ? a : b);
    final end = words
        .map((w) => w.start + w.duration)
        .reduce((a, b) => a > b ? a : b);
    if (end > first) return _spread(tokens, first, end - first);
  }
  Duration? next;
  for (var j = index + 1; j < lines.length; j++) {
    final t = lines[j].timestamp!;
    if (t > start) {
      next = t;
      break;
    }
  }
  return _spread(tokens, start, _estimatedSpan(tokens, start, next));
}
