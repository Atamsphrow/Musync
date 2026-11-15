import 'package:flutter/foundation.dart';
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

/// Une unité de mot : une suite maximale de fragments consécutifs collés
/// (séparateur `''`) et de même `isBackground`. Niveau RENDU seulement —
/// le modèle `LyricLine` / `LyricWord` ne change pas.
///
/// Cas normal (un fragment par mot) : une unité = un fragment.
@immutable
class KaraokeUnit {
  /// Index (dans `line.words`) du premier et du dernier fragment.
  final int firstIndex;
  final int lastIndex;

  /// Texte joint des fragments (« Per » + « co » + « cet » → « Percocet »).
  final String text;

  /// Séparateur entre l'unité précédente et celle-ci (`' '` ou `''`) ;
  /// `''` pour la première unité.
  final String separatorBefore;

  final bool isBackground;

  /// Début du premier fragment.
  final Duration start;

  /// Fin du dernier fragment (début + durée).
  final Duration end;

  const KaraokeUnit({
    required this.firstIndex,
    required this.lastIndex,
    required this.text,
    required this.separatorBefore,
    required this.isBackground,
    required this.start,
    required this.end,
  });

  /// L'unité vue comme un seul mot : le balayage, le soulèvement et les
  /// lettres qui gonflent réutilisent ainsi les formules de
  /// `karaoke_math.dart` telles quelles. Pour une unité d'un seul
  /// fragment, c'est exactement ce fragment.
  LyricWord get asWord => LyricWord(
    start: start,
    duration: end > start ? end - start : Duration.zero,
    text: text,
    isBackground: isBackground,
  );

  /// Vrai quand le fragment [wordIndex] fait partie de l'unité.
  bool contains(int wordIndex) =>
      wordIndex >= firstIndex && wordIndex <= lastIndex;
}

/// Regroupe les fragments de [line] en unités de mot, dans l'ordre.
///
/// Si [karaokeWordSeparators] renvoie null (mots incohérents avec le
/// texte), chaque fragment forme sa propre unité séparée par `' '` — le
/// comportement d'avant ; les appelants gardent de toute façon la ligne
/// en repli ligne simple dans ce cas.
List<KaraokeUnit> karaokeWordUnits(LyricLine line) {
  final words = line.words;
  if (words.isEmpty) return const [];
  final seps = karaokeWordSeparators(line);
  String sepBefore(int i) => i == 0 ? '' : (seps == null ? ' ' : seps[i - 1]);

  final units = <KaraokeUnit>[];
  var first = 0;
  for (var i = 1; i <= words.length; i++) {
    final endsUnit =
        i == words.length ||
        sepBefore(i).isNotEmpty ||
        words[i].isBackground != words[first].isBackground;
    if (!endsUnit) continue;
    final last = i - 1;
    units.add(
      KaraokeUnit(
        firstIndex: first,
        lastIndex: last,
        text: [for (var j = first; j <= last; j++) words[j].text].join(),
        separatorBefore: sepBefore(first),
        isBackground: words[first].isBackground,
        start: words[first].start,
        end: words[last].start + words[last].duration,
      ),
    );
    first = i;
  }
  return units;
}
