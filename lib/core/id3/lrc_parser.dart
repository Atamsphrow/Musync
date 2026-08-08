import 'package:musync/core/id3/models/lyrics.dart';

/// Reads and writes the LRC format — `[mm:ss.cc]texte`, one line per row.
///
/// The format has no specification anyone agrees on, so this parser is
/// deliberately permissive: it accepts two- or three-digit fractions, a missing
/// fraction, `.` or `:` as the separator, and several timestamps on one row
/// (the usual way a repeated chorus is written). Anything it cannot make sense
/// of is dropped rather than raised — the lyrics come from the internet, and a
/// malformed row must not cost the user the rest of the song.
class LrcParser {
  LrcParser._();

  /// `[mm:ss]`, `[mm:ss.cc]` or `[mm:ss.mmm]`.
  static final RegExp _timestamp =
      RegExp(r'\[(\d{1,3}):([0-5]?\d)(?:[.:](\d{1,3}))?\]');

  /// `[ar:...]`, `[offset:-500]` — metadata rather than a timed line. Matched
  /// on shape (letters, then a colon) so unlisted tags don't leak into the
  /// lyrics as text.
  static final RegExp _metadata = RegExp(r'^\[([a-zA-Z_]+):(.*)\]$');

  static SyncedLyrics parse(String lrcContent) {
    final lyricLines = <LyricLine>[];
    var offset = Duration.zero;

    for (final raw in lrcContent.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      final meta = _metadata.firstMatch(line);
      if (meta != null) {
        // `[offset:]` shifts the whole file, in milliseconds. Positive means
        // the lyrics should appear *earlier*, per the de-facto convention.
        if (meta.group(1)!.toLowerCase() == 'offset') {
          final ms = int.tryParse(meta.group(2)!.trim());
          if (ms != null) offset = Duration(milliseconds: -ms);
        }
        continue;
      }

      // Only the run of timestamps at the head of the row belongs to it. A
      // `[00:12]` further in is part of the lyric — a spoken aside, a stage
      // direction — and consuming it would swallow the words before it.
      final matches = <RegExpMatch>[];
      var cursor = 0;
      for (final match in _timestamp.allMatches(line)) {
        if (match.start != cursor) break;
        matches.add(match);
        cursor = match.end;
      }
      if (matches.isEmpty) continue;

      final text = line.substring(cursor).trim();

      for (final match in matches) {
        final stamp = _toDuration(match) + offset;
        lyricLines.add(LyricLine(
          timestamp: stamp.isNegative ? Duration.zero : stamp,
          text: text,
        ));
      }
    }

    return SyncedLyrics(lyricLines);
  }

  static Duration _toDuration(RegExpMatch match) {
    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);

    // A two-digit fraction is centiseconds, three is milliseconds — the digit
    // count is the only thing that says which.
    final fraction = match.group(3);
    final milliseconds = switch (fraction?.length) {
      1 => int.parse(fraction!) * 100,
      2 => int.parse(fraction!) * 10,
      3 => int.parse(fraction!),
      _ => 0,
    };

    return Duration(
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  }

  static String generate(SyncedLyrics lyrics) {
    return lyrics.lines
        .map((line) => '[${formatTimestamp(line.timestamp)}]${line.text}')
        .join('\n');
  }

  /// `mm:ss.cc`, the form used both in LRC output and in the sync editor.
  static String formatTimestamp(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    final centiseconds =
        ((d.inMilliseconds % 1000) ~/ 10).toString().padLeft(2, '0');
    return '$minutes:$seconds.$centiseconds';
  }
}
