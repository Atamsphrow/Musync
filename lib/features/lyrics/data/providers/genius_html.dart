import 'package:musync/core/utils/text_search.dart';

/// The plain lyrics of a Genius song page, as text.
///
/// The page's lyrics live in `<div data-lyrics-container="true">`
/// blocks (nested divs balanced); the header blocks
/// (`<div data-exclude-from-selection="true">` — contributors,
/// translations, the song's description) are cut out, `<br>` becomes a
/// line break, the remaining tags are stripped, and the entities are
/// decoded. Null when the page carries no lyrics container at all.
///
/// The idea (containers, header blocks, balanced divs) is myspoti's
/// `geniusText` (`LyricsApi.kt`), re-implemented in Dart from the idea
/// (GPL-3.0 — no Kotlin was copied). No HTML parser dependency: the
/// extraction is narrow and the failure is safe — a page whose markup
/// changed simply yields no lyrics.
String? extractGeniusLyrics(String html) {
  final parts = <String>[];
  var searchFrom = 0;
  while (true) {
    final matches = _containerPattern.allMatches(html, searchFrom);
    if (matches.isEmpty) break;
    final match = matches.first;
    final contentStart = match.end;
    final contentEnd = _divEnd(html, contentStart);
    if (contentEnd < 0) break;
    final part = _plainText(
      _withoutHeader(html.substring(contentStart, contentEnd)),
    );
    if (part.isNotEmpty) parts.add(part);
    searchFrom = contentEnd;
  }
  if (parts.isEmpty) return null;
  final lines = parts
      .join('\n')
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.isEmpty) return null;
  return lines.join('\n');
}

/// A Genius hit is the song: one of its artists is ours and its title
/// is ours, after the bracket asides are stripped
/// ("Kendrick Lamar (Ft. Rihanna)", "IU (아이유)", a romanized title
/// "夜に駆ける (Yoru Ni Kakeru)", co-artists "Stromae & Pomme"). The
/// titles must still be the same ("Hello Again" is not "Hello"): Genius
/// gives no length to tell two songs apart.
bool geniusMatch({
  required String candidateTitle,
  required String candidateArtists,
  required String primaryArtist,
  required String title,
  required String artist,
}) {
  final names = <String>{
    ...candidateArtists
        .replaceAll(_asidePattern, '')
        .split(RegExp(r'[, &/]+'))
        .map(foldForSearch),
    foldForSearch(candidateArtists.replaceAll(_asidePattern, '')),
    foldForSearch(primaryArtist.replaceAll(_asidePattern, '')),
  }..remove('');
  final wanted = foldForSearch(artist);
  if (wanted.isEmpty || !names.contains(wanted)) return false;
  final bareCandidate = _bareTitle(candidateTitle);
  final bareQuery = _bareTitle(title);
  return bareCandidate.isNotEmpty && bareCandidate == bareQuery;
}

/// The title without its asides: "(feat. …)", "- Remastered 2011",
/// "[Live]". A trailing bracket aside is stripped too ("Blinding
/// Lights (Remix)" is "Blinding Lights"); when that leaves nothing,
/// the cleaned title stands.
String _bareTitle(String title) {
  final cleaned = _cleanTitle(title);
  final bare = foldForSearch(
    cleaned.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), ''),
  );
  return bare.isEmpty ? foldForSearch(cleaned) : bare;
}

/// The title without its "feat." / "Remastered" asides — the same
/// cleaning the other providers use for their queries.
String _cleanTitle(String title) => title
    .replaceAll(
      RegExp(
        r'\s*[(\[][^)\]]*(feat\.?|ft\.?|with|prod)[^)\]]*[)\]]',
        caseSensitive: false,
      ),
      '',
    )
    .replaceAll(
      RegExp(
        r'\s+-\s+.*(remaster|version|edit|live|mix|mono|stereo).*$',
        caseSensitive: false,
      ),
      '',
    )
    .trim();

/// The title a Genius search is asked for: cleaned, first artist only
/// after the comma.
String geniusQuery({required String title, required String artist}) {
  final clean = _cleanTitle(title);
  final firstArtist = artist.split(',').first.trim();
  return '$clean $firstArtist'.trim();
}

final _containerPattern = RegExp(
  r'<div[^>]*data-lyrics-container="true"[^>]*>',
  caseSensitive: false,
);

final _headerPattern = RegExp(
  r'<div[^>]*data-exclude-from-selection="true"[^>]*>',
  caseSensitive: false,
);

final _asidePattern = RegExp(r'\s*\([^)]*\)');

/// Where the div whose content starts at [from] closes (nested divs
/// balanced), or -1.
int _divEnd(String html, int from) {
  var depth = 1;
  var i = from;
  while (i < html.length) {
    if (html.startsWith('<div', i) ||
        html.startsWith('<DIV', i)) {
      depth++;
    } else if (html.startsWith('</div', i) ||
        html.startsWith('</DIV', i)) {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

/// [part] without Genius's header blocks.
String _withoutHeader(String part) {
  var out = part;
  while (true) {
    final match = _headerPattern.firstMatch(out);
    if (match == null) return out;
    final end = _divEnd(out, match.end);
    if (end < 0) return out;
    final close = out.indexOf('>', end);
    if (close < 0) return out;
    out = out.replaceRange(match.start, close + 1, '');
  }
}

/// [part] as text: `<br>` becomes a line break, the remaining tags are
/// stripped, the entities decoded.
String _plainText(String part) {
  final withBreaks = part.replaceAll(
    RegExp(r'<br\s*/?>', caseSensitive: false),
    '\n',
  );
  final stripped = withBreaks.replaceAll(RegExp(r'<[^>]*>'), '');
  return _decodeEntities(stripped).trim();
}

/// The entities a lyrics page carries: named ones, then the numeric
/// references. `&amp;` goes last, so `&amp;#39;` stays the literal
/// text `&#39;` instead of becoming an apostrophe.
String _decodeEntities(String text) {
  var out = text;
  out = out.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]+);'),
    (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
  );
  out = out.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) => String.fromCharCode(int.parse(m[1]!)),
  );
  const named = {
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&#39;': "'",
    '&#x27;': "'",
  };
  for (final entry in named.entries) {
    out = out.replaceAll(entry.key, entry.value);
  }
  return out.replaceAll('&amp;', '&');
}
