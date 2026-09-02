/// Text folding for the library's live filter.
///
/// Searching is a comparison between what someone typed and what a tagger
/// wrote, and the two rarely agree on diacritics. Nobody reaches for `é` on a
/// phone keyboard to find *Été*, and a tagger who typed *Maitre GIMS* should
/// still turn up for `maître`. Matching has to work in both directions, so both
/// sides are folded before they are compared.
library;

/// Characters that fold to a plain ASCII letter.
///
/// Covers Latin-1 Supplement and the parts of Latin Extended-A that show up in
/// French and Malagasy tags — the two languages this library is actually full
/// of. Anything outside the table is left alone, which is the right answer for
/// scripts where stripping marks would change the word rather than normalise
/// it.
const Map<String, String> _folded = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
  'ă': 'a', 'ą': 'a',
  'ç': 'c', 'ć': 'c', 'ĉ': 'c', 'ċ': 'c', 'č': 'c',
  'ď': 'd', 'đ': 'd',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e',
  'ę': 'e', 'ě': 'e',
  'ĝ': 'g', 'ğ': 'g', 'ġ': 'g', 'ģ': 'g',
  'ĥ': 'h', 'ħ': 'h',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i',
  'į': 'i', 'ı': 'i',
  'ĵ': 'j',
  'ķ': 'k',
  'ĺ': 'l', 'ļ': 'l', 'ľ': 'l', 'ł': 'l',
  'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
  'ŏ': 'o', 'ő': 'o',
  'ŕ': 'r', 'ŗ': 'r', 'ř': 'r',
  'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's',
  'ţ': 't', 'ť': 't', 'ŧ': 't',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u',
  'ů': 'u', 'ű': 'u', 'ų': 'u',
  'ŵ': 'w',
  'ý': 'y', 'ÿ': 'y', 'ŷ': 'y',
  'ź': 'z', 'ż': 'z', 'ž': 'z',
  // Ligatures, which fold to two letters rather than one.
  'æ': 'ae', 'œ': 'oe', 'ß': 'ss',
};

/// Lower-cases [text] and strips the diacritics this app is likely to meet.
///
/// Cheap enough to run over a whole library on every keystroke: one pass, and
/// the common case — a string with no accented character at all — allocates
/// nothing beyond the lower-cased copy.
String foldForSearch(String text) {
  final lower = text.toLowerCase();

  // Fast path. Most titles are plain ASCII, and there is no point walking them
  // character by character to discover that.
  var needsFolding = false;
  for (var i = 0; i < lower.length; i++) {
    if (lower.codeUnitAt(i) > 0x7F) {
      needsFolding = true;
      break;
    }
  }
  if (!needsFolding) return lower;

  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_folded[char] ?? char);
  }
  return buffer.toString();
}
