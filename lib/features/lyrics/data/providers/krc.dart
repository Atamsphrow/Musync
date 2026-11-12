/// Kugou's KRC lyrics: decryption and parsing.
///
/// KRC is Kugou's encrypted lyric format. The `content` string the
/// download endpoint returns is base64; after decoding, the first four
/// bytes are a header to skip, the rest is XORed with a fixed 16-byte key
/// (cyclic) and zlib-compressed. The key is public knowledge — it ships in
/// myspoti's code and in every KRC tool — this is obfuscation, not
/// encryption, and decrypting it here is what lets a player read lyrics
/// the service hands out freely.
///
/// A KRC line is `[(start),(duration)]` followed by words
/// `<(offset),(duration),?>text`, where the offsets are relative to the
/// line. Header tags (`[ti:]`, `[ar:]`, `[al:]`, `[language:]` — the last
/// one a large base64 blob) never match the line shape and are ignored.
/// Credit lines (`Lyrics by：…`, `Composed by：…`, `Produced by：…`) and
/// the title line (a line at 0 ms whose text is exactly
/// "`song` - `singer`", words with junk timings) are dropped: neither is
/// a lyric.
///
/// The idea (endpoints, XOR key, line/word shapes, the 3-line minimum)
/// is myspoti's `LyricsApi.kt:983-1015`, re-implemented in Dart from the
/// idea (GPL-3.0 — no Kotlin was copied). The live KRC this was verified
/// against is The Weeknd « Blinding Lights », 2026-11-12.
library;

import 'dart:convert';
import 'dart:io';

import 'package:musync/core/id3/models/lyrics.dart';

/// The fixed XOR key, cyclic over the compressed bytes.
const List<int> _krcKey = [
  64,
  71,
  97,
  119,
  94,
  50,
  116,
  71,
  81,
  54,
  49,
  45,
  206,
  210,
  110,
  105,
];

final _krcLine = RegExp(r'^\[(\d+),(\d+)](.*)$');
final _krcWord = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');

/// Decrypts a KRC `content` string into plain KRC text, or null when the
/// payload is not a KRC at all (bad base64, too short to hold a header,
/// zlib that does not inflate, text that is not UTF-8).
String? decryptKrc(String content) {
  try {
    final raw = base64Decode(content);
    if (raw.length <= 4) return null;
    final xored = List<int>.generate(
      raw.length - 4,
      (i) => raw[i + 4] ^ _krcKey[i % _krcKey.length],
    );
    return utf8.decode(ZLibDecoder().convert(xored));
  } catch (_) {
    return null;
  }
}

/// Parses decrypted KRC text into timed lines, or null when it carries
/// fewer than three usable lines — a fragment is not a song's lyrics.
///
/// [song] and [singer] are the candidate's own, as the search returned
/// them: the title line is identified by its text, "`song` - `singer`".
List<LyricLine>? parseKrcLyrics(
  String krc, {
  required String song,
  required String singer,
}) {
  final lines = <LyricLine>[];
  for (final raw in krc.split('\n')) {
    final m = _krcLine.firstMatch(raw.trim());
    if (m == null) continue;
    final start = int.parse(m.group(1)!);
    final words = <LyricWord>[
      for (final w in _krcWord.allMatches(m.group(3)!))
        LyricWord(
          start: Duration(milliseconds: start + int.parse(w.group(1)!)),
          duration: Duration(milliseconds: int.parse(w.group(2)!)),
          text: w.group(3)!,
        ),
    ];
    final text = words.map((w) => w.text).join().trim();
    if (text.isEmpty || text.contains('：')) continue;
    // The title line: same shape as a lyric, but it is the song's name.
    if (start == 0 && text == '$song - $singer') continue;
    lines.add(
      LyricLine(
        timestamp: Duration(milliseconds: start),
        text: text,
        words: words,
      ),
    );
  }
  return lines.length >= 3 ? lines : null;
}
