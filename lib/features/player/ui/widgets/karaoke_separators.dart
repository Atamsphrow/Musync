import 'package:musync/core/id3/models/lyrics.dart';

/// Séparateurs entre les mots d'une ligne, lus dans `line.text`.
/// `result[i]` = texte entre le mot i et le mot i+1 : `' '` si le texte
/// a un espace à cet endroit, `''` pour une coupure de syllabe
/// (« nev » → « er »). Renvoie null si les mots ne recouvrent pas
/// exactement le texte (ligne incohérente → repli ligne simple).
List<String>? karaokeWordSeparators(LyricLine line) {
  final text = line.text;
  final words = line.words;
  if (words.isEmpty) return null;

  bool isSpace(int i) => text[i].trim().isEmpty;
  var pos = 0;
  while (pos < text.length && isSpace(pos)) {
    pos++;
  }

  final separators = <String>[];
  for (var i = 0; i < words.length; i++) {
    final w = words[i].text;
    if (w.isEmpty || !text.startsWith(w, pos)) return null;
    pos += w.length;
    if (i == words.length - 1) break;
    if (pos < text.length && isSpace(pos)) {
      while (pos < text.length && isSpace(pos)) {
        pos++;
      }
      separators.add(' ');
    } else {
      separators.add('');
    }
  }
  while (pos < text.length && isSpace(pos)) {
    pos++;
  }
  return pos == text.length ? separators : null;
}
