/// Re-time lyrics that come from another recording to the one in the file.
///
/// LyricsPlus and lrc.red time the Apple Music recording; the file the user
/// owns is often another cut, whose intro differs by a few seconds. Writing
/// those timings as-is would put every line early or late until the user
/// nudges them by hand. This re-times them first, from the timings the file
/// already has — the calibration the user may have done by hand is the
/// trusted reference.
///
/// The algorithm is myspoti's `alignTo`, re-implemented from the idea
/// (GPL-3.0 — no Kotlin was copied): pair the lines that appear exactly
/// once on each side, take the median of their time gaps, and shift the
/// whole incoming set — words included — when enough lines agree. The
/// constants are myspoti's, unchanged: on Musync's own measurement
/// (lrc.red vs LRCLIB on the same track: 100–330 ms) they sit comfortably
/// inside the tolerance, so there is no evidence for loosening them.
library;

import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/utils/text_search.dart';

/// The sources whose timings come from another recording (Apple Music),
/// rather than from the file's own cut (LRCLIB, which times the file's
/// recording). Only their results are aligned before integration.
bool isOtherRecordingSource(String source) =>
    source == 'LyricsPlus' || source == 'lrc.red' || source == 'Kugou';

/// How far two lines may sit from the median gap and still agree with it.
/// A line that disagrees by more than this is a different cut's line, not
/// the same line mistimed.
const Duration _alignTolerance = Duration(milliseconds: 1500);

/// The most two recordings' intros are taken to differ by; more is another
/// cut or a wrong pairing.
const Duration _maxAlignShift = Duration(seconds: 20);

/// A shift smaller than this is noise, not an intro difference.
const Duration _minAlignShift = Duration(milliseconds: 60);

/// A line is only paired when its key is at least this long: short lines
/// ("oh", "yeah") repeat everywhere and would pair the wrong copies.
const int _minAlignKeyLength = 6;

/// The result of an alignment: the lyrics to write, the shift actually
/// applied (0 when none), and whether a shift was applied at all.
///
/// "Not aligned" never means "refused": the caller writes [lyrics] as-is.
/// An explicit apply (search screen, AI mode, batch) must not be silently
/// refused because the reference disagrees — the user chose these lyrics,
/// and a nudge fixes a bad offset afterwards.
({SyncedLyrics lyrics, int shiftMs, bool aligned}) alignLyrics({
  required SyncedLyrics incoming,
  required SyncedLyrics reference,
}) {
  if (incoming.isEmpty || reference.isEmpty) {
    return (lyrics: incoming, shiftMs: 0, aligned: false);
  }

  // The pairing key: folded (accents and case aside), letters and digits
  // only. The same normalisation myspoti's `LyricsMatch.key` applies.
  String key(String text) =>
      foldForSearch(text).replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  Map<String, int> uniqueKeys(SyncedLyrics lyrics) {
    final counts = <String, int>{};
    for (final line in lyrics.lines) {
      final k = key(line.text);
      if (k.length >= _minAlignKeyLength) {
        counts[k] = (counts[k] ?? 0) + 1;
      }
    }
    return {
      for (final entry in counts.entries)
        if (entry.value == 1) entry.key: entry.value,
    };
  }

  final incomingKeys = uniqueKeys(incoming);
  final referenceKeys = uniqueKeys(reference);
  if (incomingKeys.isEmpty || referenceKeys.isEmpty) {
    return (lyrics: incoming, shiftMs: 0, aligned: false);
  }

  // The reference's lines, keyed: only lines after the start count — a
  // line at 0 is the intro's placeholder, not a timing. (Every line in a
  // SyncedLyrics is timed — the constructor drops untimed ones — so the
  // `!` below is a type-level fact, not an assumption.)
  final referenceAt = <String, Duration>{};
  for (final line in reference.lines) {
    final k = key(line.text);
    if (line.timestamp != null &&
        line.timestamp! > Duration.zero &&
        referenceKeys.containsKey(k) &&
        incomingKeys.containsKey(k)) {
      referenceAt[k] = line.timestamp!;
    }
  }

  // The gaps, reference minus incoming, over the lines paired on both
  // sides. Only lines that appear once on each side are paired: a chorus
  // sung five times paired its first copy with a later one would move the
  // whole set by a verse.
  final gaps = <int>[];
  for (final line in incoming.lines) {
    final at = referenceAt[key(line.text)];
    if (at != null) {
      gaps.add(at.inMilliseconds - line.timestamp!.inMilliseconds);
    }
  }
  if (gaps.length < 3) {
    return (lyrics: incoming, shiftMs: 0, aligned: false);
  }

  gaps.sort();
  final shift = gaps[gaps.length ~/ 2];
  final agreeing =
      gaps.where((gap) => (gap - shift).abs() <= _alignTolerance.inMilliseconds).length;
  final needed = (gaps.length * 0.6).toInt();
  if (agreeing < (needed < 3 ? 3 : needed) ||
      shift.abs() > _maxAlignShift.inMilliseconds) {
    return (lyrics: incoming, shiftMs: 0, aligned: false);
  }
  if (shift.abs() < _minAlignShift.inMilliseconds) {
    return (lyrics: incoming, shiftMs: 0, aligned: false);
  }

  // Shift every line — and every word with it, keeping its relative
  // offset to its line — floored at zero so an early line never goes
  // negative.
  Duration shifted(Duration t) {
    final ms = t.inMilliseconds + shift;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  return (
    lyrics: SyncedLyrics([
      for (final line in incoming.lines)
        line.copyWith(
          timestamp: shifted(line.timestamp!),
          words: [
            for (final word in line.words)
              LyricWord(
                start: shifted(word.start),
                duration: word.duration,
                text: word.text,
                isBackground: word.isBackground,
              ),
          ],
        ),
    ]),
    shiftMs: shift,
    aligned: true,
  );
}
