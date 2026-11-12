import 'dart:math' as math;

import 'package:musync/core/id3/models/lyrics.dart';

/// The karaoke animation math: the sweep across the word being sung,
/// the lift as a word lands and settles back, and the letter-by-letter
/// swell of a held word.
///
/// The formulas are inspired by myspoti's `SweptLyricModel` (GPL-3.0)
/// and rewritten as new Dart — no myspoti code is copied. The constants
/// are myspoti's, because the feel of the animation lives in them:
/// the lift is only ever two pixels, the swell only ever a few percent,
/// and that restraint is what keeps the words readable while they move.
///
/// Everything here is a pure function of a word and a position, so the
/// whole animation is unit-testable without a player.

/// Smoothstep: eases a 0..1 fraction in and out of its ends, so a lift
/// has no corners on it.
double smoothstep(double t) {
  final clamped = t.clamp(0.0, 1.0);
  return clamped * clamped * (3 - 2 * clamped);
}

/// How high a word lifts, as a share of the full lift: a word sung in
/// 150 ms or less only nudges (0.25), one held 900 ms or more goes the
/// whole way (1.0), eased between — patter barely leaves the line and
/// a carried note goes all the way up.
double liftHeightFraction(LyricWord word) {
  final held = word.duration.inMilliseconds.toDouble();
  final through = ((held - 150) / (900 - 150)).clamp(0.0, 1.0);
  return 0.25 + 0.75 * smoothstep(through);
}

/// How far [word] has lifted at [position], 0..1. It rises over its own
/// length (at least 250 ms, at most 700 ms) and settles back over
/// 700 ms from its end — so a word that just ended is still visibly
/// settling while the next one starts to rise.
double wordLiftFraction({
  required LyricWord word,
  required Duration position,
}) {
  final start = word.start.inMilliseconds.toDouble();
  final end = start + word.duration.inMilliseconds.toDouble();
  final pos = position.inMilliseconds.toDouble();
  final riseMs = (end - start).clamp(250.0, 700.0);
  final rising = ((pos - start) / riseMs).clamp(0.0, 1.0);
  final falling = (1 - (pos - end) / 700).clamp(0.0, 1.0);
  return liftHeightFraction(word) * smoothstep(math.min(rising, falling));
}

/// The full lift, in logical pixels: myspoti's WORD_RISE, 2 dp — enough
/// for the eye to catch the words moving, little enough that nothing
/// looks loose from the line it belongs to.
const double karaokeFullLiftPx = 2.0;

/// How much of [word] has been sung at [position], 0..1: linear in time
/// across the word, 0 before it starts, 1 once it ends. The sweep
/// crosses a word at a steady pace of its own — a held note draws
/// slowly, a rattled-off one snaps.
double wordSweepFraction({
  required LyricWord word,
  required Duration position,
}) {
  final start = word.start.inMilliseconds.toDouble();
  final span = math.max(word.duration.inMilliseconds.toDouble(), 1.0);
  return ((position.inMilliseconds.toDouble() - start) / span)
      .clamp(0.0, 1.0);
}

/// Whether [word] is held long enough, and short enough, to be animated
/// letter by letter: the one moment in a line where there is time to see
/// anything happen to a word.
///
/// The thresholds are steeper for short words than the length alone
/// suggests: a two-letter word held for a second is a held note, whereas
/// a seven-letter one held for the same second is just being sung at an
/// ordinary pace. Scripts whose letters are not laid out side by side
/// independently are left alone — Han, kana and Hangul draw as blocks,
/// and right-to-left scripts join up, so moving one letter of a word
/// would come apart rather than swell. A hyphenated word is really two
/// words and would break at the hyphen.
bool canGrowWord(LyricWord word) {
  final text = word.text;
  final length = text.length;
  if (length == 0 || length > 7) return false;
  if (text.contains('-')) return false;
  if (text.runes.any(_isBlockOrJoinedScript)) return false;
  final held = word.duration.inMilliseconds;
  if (length == 1) return held >= 1100;
  if (length <= 3) return held >= 1360 + (length - 2) * 140;
  if (length == 4) return held >= 1050;
  return held >= 900 && held >= length * 200;
}

bool _isBlockOrJoinedScript(int rune) {
  // Han.
  if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
  // Hiragana and katakana.
  if (rune >= 0x3040 && rune <= 0x309F) return true;
  if (rune >= 0x30A0 && rune <= 0x30FF) return true;
  // Hangul syllables.
  if (rune >= 0xAC00 && rune <= 0xD7AF) return true;
  // Hebrew and Arabic: right-to-left scripts whose letters join up.
  if (rune >= 0x0590 && rune <= 0x06FF) return true;
  return false;
}

/// When the last letter of a growing [word] has finished moving and is
/// just sitting lifted. Past this the word is back to being an ordinary
/// sung word settling down.
Duration growingWordRestsAt(LyricWord word) {
  final held =
      math.max(word.duration.inMilliseconds, 1).toDouble();
  final last = (word.text.length - 1).clamp(0, 6) * 0.09 + 1.5;
  return word.start +
      Duration(milliseconds: (held * last).round());
}

/// Whether [word] is mid-flight at [position]: held long enough to grow,
/// started, and its last letter not yet at rest.
bool isGrowingWord(LyricWord word, Duration position) =>
    canGrowWord(word) &&
    position >= word.start &&
    position <= growingWordRestsAt(word);

/// One letter's place in a growing word's move at [position]:
/// [scale] (1 = as laid out), [shiftEm] (lean away from the word's
/// middle, in ems), [rise] (multiples of the ordinary lift) and
/// [bloom] (0..1, the glow).
///
/// Every letter runs the same three-beat move — swell up and forward,
/// hold, then settle back to the small lift every sung word carries —
/// but each one starts 9 % of the word's length after the one before
/// it, so the movement travels along the word instead of the whole
/// thing pulsing at once. The peaks differ letter by letter as well:
/// later letters of a long word, and every letter of a word only just
/// held long enough to qualify, move and light less — without that a
/// seven-letter word read as a wave with a tail that kept going after
/// the singer had stopped.
///
/// The peaks depend only on the word — its length and how long it is
/// held — while the frame only ever asks where in the move a given
/// letter has got to.
({double scale, double shiftEm, double rise, double bloom}) growingLetter({
  required LyricWord word,
  required int charIndex,
  required Duration position,
}) {
  final text = word.text;
  final chars = text.length;
  final startMs = word.start.inMilliseconds.toDouble();
  final endMs = startMs + word.duration.inMilliseconds.toDouble();
  final held = math.max(endMs - startMs, 1.0);
  final posMs = position.inMilliseconds.toDouble();

  // How much of the full treatment this word has earned. Cubed, so the
  // difference between a word held for a second and one held for three
  // is most of the range and everything under a second is barely
  // anything — the alternative reads as every word twitching.
  final earned = ((held - 400) / (3000 - 400)).clamp(0.0, 1.0);
  final earnedCubed = earned * earned * earned;
  final decay = _decayRate(chars, held);
  // A word barely over the line glows less than one held twice as long,
  // and a long word spreads what it has over more letters.
  final bloomPace = math.min(1.1, held / 1500);
  final bloomSpread = chars <= 3 ? 0.85 : (chars >= 6 ? 1.1 : 1.0);
  // Short words swell a little more, having fewer letters to do it with.
  final base = chars <= 3 ? 0.05 : 0.04;
  final liftPace = (held / 2000).clamp(0.3, 1.0);

  final place = chars > 1 ? charIndex / (chars - 1) : 0.0;
  final reach = earnedCubed * (1 - place * decay);
  final scale = 1 + base + reach * 0.08;
  final scalePeak = scale * 0.98;
  final bloomPeak = (0.35 + reach * 0.45) * bloomPace * bloomSpread;
  // The lift is read off the swell rather than set on its own: a
  // letter that grows more rises further, which is what keeps the two
  // reading as one movement instead of two.
  final risePeak = ((scale - 1) / 0.1) * liftPace;
  // Letters lean away from the middle of the word as it swells, so it
  // opens outwards rather than every letter sliding the same way.
  final centre = (charIndex + 0.5) / chars;
  final shiftPeak = (centre - 0.5) * 2 * (scale - 1) * (25 / 34) * 0.98;

  final span = math.max(endMs - startMs, 1.0);
  final elapsed = posMs - startMs - charIndex * span * 0.09;
  final phase = (elapsed / (span * 1.5)).clamp(0.0, 1.0);
  if (phase < 0.25) {
    final t = smoothstep(phase / 0.25);
    return (
      scale: 1 + (scalePeak - 1) * t,
      shiftEm: shiftPeak * t,
      rise: risePeak * t,
      bloom: bloomPeak * t,
    );
  }
  if (phase < 0.30) {
    return (
      scale: scalePeak,
      shiftEm: shiftPeak,
      rise: risePeak,
      bloom: bloomPeak,
    );
  }
  if (phase < 0.75) {
    final t = smoothstep((phase - 0.30) / (0.75 - 0.30));
    return (
      scale: scalePeak + (1 - scalePeak) * t,
      shiftEm: shiftPeak * (1 - t),
      rise: risePeak + (1 - risePeak) * t,
      bloom: bloomPeak * (1 - t),
    );
  }
  // At rest: back to the ordinary sung lift, no glow.
  return (scale: 1.0, shiftEm: 0.0, rise: 1.0, bloom: 0.0);
}

/// How much of the movement is taken back off the later letters of a
/// word. Two reasons to hold back: a long word is a lot of letters to
/// run a wave through, and left flat the tail of it is still swelling
/// well after the singer has moved on; a word held only just long enough
/// to qualify has no room for a wave at all, so the whole thing is
/// damped towards a single swell.
double _decayRate(int length, double heldMs) {
  final long = length > 5;
  final quick = heldMs < 1200;
  if (!long && !quick) return 0.0;
  var strength = 0.0;
  if (long) {
    strength += math.min((length - 5) / 5, 1.0) * 0.4;
  }
  if (quick) {
    final short = math.max(0.0, 1 - (heldMs - 800) / 400);
    strength += short * (length > 3 ? 0.3 : 0.1);
  }
  return math.min(strength, 0.7);
}
