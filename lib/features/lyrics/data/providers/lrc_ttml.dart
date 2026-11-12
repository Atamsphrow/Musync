/// TTML lyrics parsing for the lrc.red source (step 2 of the myspoti plan).
///
/// Pure functions, no network: the provider fetches, this file only reads.
///
/// The subset lrc.red actually emits (verified live 2026-11-12):
///
/// ```xml
/// <tt xmlns="http://www.w3.org/ns/ttml"
///     xmlns:lrc="http://lrc.red/lyric-ttml-internal" lrc:timing="Line">
///   <body dur="2:50.539">
///     <div begin="4.008" end="22.846" lrc:songPart="Verse">
///       <p begin="4.008" end="8.526" lrc:key="L750">Ooh, ooh, whoa</p>
///       <p begin="9.946" end="11.928">I never been scared</p>
///     </div>
///   </body>
/// </tt>
/// ```
///
/// Word timings, when the catalogue has them, arrive as `<span>` children of
/// a `<p>` (`<span begin="..." end="...">word</span>`, choir spans carry
/// `ttm:role="x-bg"`). A track the source only knows as text has `<p>` with
/// no `begin` at all (`lrc:timing="None"`).
///
/// Classification is on the numbers, never on `lrc:timing` — the same rule
/// as LyricsPlus: a `<p>` without `begin` is an untimed line, and a response
/// is synced only when at least one line carries a positive time or at
/// least one word timing.
library;

import 'package:xml/xml.dart';

import 'package:musync/core/id3/models/lyrics.dart';

/// A TTML clock time in milliseconds, or null when the value is missing or
/// unparseable.
///
/// Shapes: seconds decimals ("4.008"), `m:ss.mmm` ("1:00.672"),
/// `h:mm:ss.mmm` ("01:04:08.500"). A negative value is a broken payload,
/// not a cue — null, like an unparseable one.
int? parseTtmlTime(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final parts = trimmed.split(':');
  double seconds;
  if (parts.length == 1) {
    final parsed = double.tryParse(parts[0]);
    if (parsed == null || parsed < 0) return null;
    seconds = parsed;
  } else if (parts.length == 2) {
    final minutes = int.tryParse(parts[0]);
    final parsed = double.tryParse(parts[1]);
    if (minutes == null || parsed == null || minutes < 0 || parsed < 0) {
      return null;
    }
    seconds = minutes * 60 + parsed;
  } else if (parts.length == 3) {
    final hours = int.tryParse(parts[0]);
    final minutes = int.tryParse(parts[1]);
    final parsed = double.tryParse(parts[2]);
    if (hours == null ||
        minutes == null ||
        parsed == null ||
        hours < 0 ||
        minutes < 0 ||
        parsed < 0) {
      return null;
    }
    seconds = hours * 3600 + minutes * 60 + parsed;
  } else {
    return null;
  }
  return (seconds * 1000).round();
}

/// Parses a TTML document into lyric lines, or null when it carries nothing
/// usable — malformed XML, no `<p>` at all, or every `<p>` empty or
/// unusable.
///
/// Rules, each pinned by a test:
/// - A `<p>` with a `begin` gets that timestamp; without one it is an
///   untimed line (`timestamp: null`). A `begin` present but unparseable
///   drops the line: its timing is unknown, and an untimed line inside a
///   synced set would sort to the end and flash at the wrong moment.
/// - Word timings come from `<span>` children with a `begin`. A `<span>`
///   without one still contributes its text to the line, but no [LyricWord]
///   — a word with no timing is not a timed word.
/// - `ttm:role="x-bg"` marks a choir/background word.
/// - `<br/>` inside a `<p>` becomes a space: the LRC/SYLT writers the app
///   uses cannot emit a newline inside one line, and a space keeps the
///   words readable instead of glued together.
/// - Unknown elements and attributes (`lrc:key`, `lrc:songPart`,
///   `ttm:agent`, translations, `leadingSilence`, `body dur`) are ignored.
///   `leadingSilence` is tens of milliseconds at most — below the 100 ms
///   nudge step — and the `<p>` times are absolute track times (checked
///   against LRCLIB on « Scared of Love »: 4.008 s vs 00:04.26, the same
///   line, the gap being inter-source jitter, not a missing offset).
List<LyricLine>? parseTtmlLyrics(String ttml) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(ttml);
  } on XmlException {
    return null;
  }

  final lines = <LyricLine>[];
  for (final p in document.findAllElements('p')) {
    final line = _parseLine(p);
    if (line != null) lines.add(line);
  }
  return lines.isEmpty ? null : lines;
}

LyricLine? _parseLine(XmlElement p) {
  final beginAttr = p.getAttribute('begin');
  Duration? timestamp;
  if (beginAttr != null) {
    final beginMs = parseTtmlTime(beginAttr);
    if (beginMs == null) return null;
    timestamp = Duration(milliseconds: beginMs);
  }

  final text = _collectText(p);
  if (text.isEmpty) return null;

  final words = <LyricWord>[];
  for (final span in p.findElements('span')) {
    final word = _parseWord(span);
    if (word != null) words.add(word);
  }

  return LyricLine(
    timestamp: timestamp,
    text: text,
    words: List.unmodifiable(words),
  );
}

LyricWord? _parseWord(XmlElement span) {
  final beginAttr = span.getAttribute('begin');
  if (beginAttr == null) return null;
  final beginMs = parseTtmlTime(beginAttr);
  if (beginMs == null) return null;

  final text = _collectText(span);
  if (text.isEmpty) return null;

  var duration = Duration.zero;
  final endAttr = span.getAttribute('end');
  if (endAttr != null) {
    final endMs = parseTtmlTime(endAttr);
    if (endMs != null && endMs > beginMs) {
      duration = Duration(milliseconds: endMs - beginMs);
    }
  }

  return LyricWord(
    start: Duration(milliseconds: beginMs),
    duration: duration,
    text: text,
    isBackground: span.getAttribute('ttm:role') == 'x-bg',
  );
}

/// The readable text of a node: text nodes as-is, `<br/>` as a space, every
/// other element recursed into. Runs of whitespace collapse to one space,
/// and the result is trimmed — TTML from this source is one long line of
/// XML, so indentation whitespace must never reach the lyrics.
String _collectText(XmlNode node) {
  final buffer = StringBuffer();
  for (final child in node.children) {
    if (child is XmlText) {
      buffer.write(child.value);
    } else if (child is XmlElement) {
      if (child.name.local == 'br') {
        buffer.write(' ');
      } else {
        buffer.write(_collectText(child));
        // Two `<span>` words written back to back with no whitespace
        // between them in the source would glue together ("ligne" +
        // "ooh" = "ligneooh"). A space after each span keeps the words
        // apart; the whitespace collapse below swallows the extra one
        // when the source already separates them.
        if (child.name.local == 'span') buffer.write(' ');
      }
    }
  }
  return buffer
      .toString()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
