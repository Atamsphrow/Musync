/// Variantes de requête pour le 2e essai automatique de la recherche de
/// paroles : complet → nettoyé → titre seul.
///
/// Fonctions pures, sans Flutter ni réseau : testables telles quelles.
///
/// Le test A/B du 2026-11-15 a montré que Kugou, NetEase et lrc.red
/// échouent sur les titres décorés (« feat. X », « (Live at …) »), alors
/// que la version nettoyée passe. La version complète reste essayée en
/// premier : quand elle trouve, ce sont les paroles de la bonne version
/// (les timings d'un live ou d'un remix ne sont pas ceux de l'original).
library;

/// Une requête à essayer.
typedef SearchVariant = ({String title, String artist});

/// Mots qui, à eux seuls, font d'un groupe entre parenthèses ou crochets
/// une décoration de téléchargement (`(Official Video 2017)`).
///
/// Volontairement dupliquée depuis `FilenameParser` : ses listes sont
/// privées. À unifier si on rend `readsAsJunk` public.
const Set<String> _junkWords = {
  'official',
  'officiel',
  'officielle',
  'video',
  'vidéo',
  'clip',
  'lyrics',
  'lyric',
  'paroles',
  'visualizer',
  'audio',
  'hd',
  'hq',
  'youtube',
  'mp3',
  'mp4',
  'download',
  'oficial',
  'videoclip',
  'mv',
  'visualiser',
  'letra',
  'uhd',
};

/// Words that may sit in a decoration group without being decoration on
/// their own: `(Official Music Video)`, `(Official Video with Lyrics)` are
/// decoration, `(Music)` alone is not.
const Set<String> _neutralWords = {
  'music',
  'musique',
  'musica',
  'with',
  'and',
  'avec',
  'et',
  'con',
  'y',
  'the',
  'en',
  'w',
};

/// `1080p`, `320kbps`, `4k`. Une année seule n'en fait pas partie.
final RegExp _quality = RegExp(r'^(?:\d{3,4}p|\d{2,4}k(?:bps)?|[48]k)$');

/// Une année : tolérée à l'intérieur d'un groupe de décoration, mais
/// jamais décoration à elle seule (`(1999)` peut être un vrai titre).
final RegExp _year = RegExp(r'^(?:19|20)\d{2}$');

final RegExp _bracketed = RegExp(r'[\(\[]([^\(\)\[\]]*)[\)\]]');

/// Séparateur de mots défini sur les lettres/chiffres Unicode, comme dans
/// `FilenameParser` (`\b` de Dart ne connaît pas `é`).
final RegExp _wordSplit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// `feat. X`, `ft. X`, `featuring X` sans parenthèses, jusqu'à la fin.
/// Il faut une espace avant : « Left Behind » n'est pas touché.
final RegExp _trailingFeat = RegExp(
  r'\s+(?:feat\.?|ft\.?|featuring)\s+.+$',
  caseSensitive: false,
);

final RegExp _hashtag = RegExp(r'\s#\S+');

List<String> _words(String text) => text
    .toLowerCase()
    .split(_wordSplit)
    .where((w) => w.isNotEmpty)
    .toList();

/// Le contenu d'un groupe est-il une décoration à retirer ?
///
/// Conservateur : mieux vaut laisser une parenthèse que casser un vrai
/// titre. `(I Can't Get No) Satisfaction`, `(Live Forever)`,
/// `(With a Little Help…)` restent intacts.
bool _isDecoration(String inner) {
  final words = _words(inner);
  if (words.isEmpty) return false;

  // (feat. X), (ft. X), (featuring X). « with » est volontairement absent :
  // « (With a Little Help from My Friends) » est un vrai titre.
  if (const {'feat', 'ft', 'featuring'}.contains(words.first)) {
    return words.length > 1;
  }

  // Décoration de téléchargement : que des mots parasites, des années, des
  // résolutions ou des mots neutres, avec au moins un mot parasite ou une
  // résolution.
  final allNoise = words.every(
    (w) =>
        _junkWords.contains(w) ||
        _neutralWords.contains(w) ||
        _quality.hasMatch(w) ||
        _year.hasMatch(w),
  );
  final anySignal = words.any(
    (w) => _junkWords.contains(w) || _quality.hasMatch(w),
  );
  if (allNoise && anySignal) return true;

  // Versions : (Remix), (ANATI Remix 2018), (2011 Remaster).
  if (words.any((w) => w == 'remix' || w == 'remixed' || w.startsWith('remaster'))) {
    return true;
  }

  // (Live), (Live at …), mais pas (Live Forever).
  if (words.first == 'live' &&
      (words.length == 1 ||
          const {
            'at',
            'in',
            'from',
            'on',
            'session',
            'sessions',
            'version',
            'performance',
          }.contains(words[1]))) {
    return true;
  }

  // (Acoustic), (Instrumental), (Karaoke), (Explicit) en premier ou
  // dernier mot ; (Clean) seul.
  const alone = {'acoustic', 'instrumental', 'karaoke', 'explicit'};
  if (alone.contains(words.first) || alone.contains(words.last)) return true;
  if (words.length == 1 && words.first == 'clean') return true;

  // (From the Motion Picture …), (From "Frozen") : une bande originale.
  if (words.first == 'from' && words.length > 1) return true;

  // (Radio Edit), (Original Single Mono Version), (Extended Mix).
  return const {'version', 'edit', 'mix', 'mono', 'stereo'}.contains(words.last);
}

String _tidy(String text) => text
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'^[\s\-–—_,]+|[\s\-–—_,]+$'), '')
    .trim();

/// ` - Remastered 2011`, ` - Live`, ` - Radio Edit` : la version que les
/// services de streaming ajoutent après un tiret, hors parenthèses. Seule
/// la dernière partie, et seulement quand elle se lit comme une décoration
/// (`Stand By Me - Ben E. King` reste entier).
final RegExp _dashSuffix = RegExp(r'\s+[-–—]\s+([^\-–—]+)$');

String _clean(String text) {
  var cleaned = text.replaceAllMapped(
    _bracketed,
    (m) => _isDecoration(m.group(1) ?? '') ? '' : m.group(0)!,
  );
  final suffix = _dashSuffix.firstMatch(cleaned);
  if (suffix != null &&
      suffix.start > 0 &&
      _isDecoration(suffix.group(1)!.replaceAll(RegExp('["“”«»]'), ''))) {
    cleaned = cleaned.substring(0, suffix.start);
  }
  cleaned = cleaned.replaceFirst(_trailingFeat, '');
  cleaned = cleaned.replaceAll(_hashtag, '');
  // Groupes imbriqués : seul le plus interne est examiné, donc
  // « ((Live)) » laisse « () » — on vide ces paires résiduelles.
  cleaned = cleaned.replaceAll(RegExp(r'\(\s*\)|\[\s*\]'), '');
  cleaned = _tidy(cleaned);
  // Un titre fait uniquement de décoration (« (Live) ») : on le garde tel
  // quel plutôt que de chercher une chaîne vide.
  return cleaned.isEmpty ? _tidy(text) : cleaned;
}

/// [title] sans feat., Remix, Live, Acoustic, mentions vidéo, résolutions…
/// Les parenthèses qui font partie du vrai titre sont conservées.
String cleanSearchTitle(String title) => _clean(title);

/// Où s'arrête l'artiste principal d'une liste : `A x B`, `A vs. B`,
/// `A; B`, `A / B`. Ni `&` ni la virgule : « Simon & Garfunkel » et
/// « Earth, Wind & Fire » sont des noms. Un `x` minuscule seulement :
/// « Lil Nas X » garde son X.
final RegExp _artistListCut = RegExp(r'\s+(?:x|×|vs\.?)\s+|\s*;\s*|\s+/\s+');

/// [artist] sans invité (« Daft Punk feat. Pharrell » → « Daft Punk »),
/// réduit à l'artiste principal d'une liste (« Major Lazer x DJ Snake » →
/// « Major Lazer »). « Simon & Garfunkel » reste entier.
String cleanSearchArtist(String artist) {
  final cleaned = _clean(artist);
  final cut = _artistListCut.firstMatch(cleaned);
  if (cut == null || cut.start == 0) return cleaned;
  final main = _tidy(cleaned.substring(0, cut.start));
  return main.isEmpty ? cleaned : main;
}

String _key(String title, String artist) =>
    '${title.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim()}\u0000'
    '${artist.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim()}';

/// Les requêtes à essayer après [usedTitle]/[usedArtist], dans l'ordre :
///
/// 1. **complet** : le deviné tel quel (bonne version quand il trouve) ;
/// 2. **nettoyé** : le même sans décorations ;
/// 3. **titre seul** : sans artiste, quand l'artiste est mal deviné.
///
/// [mayBeReversed] : le deviné vient de la seule heuristique, qui lit
/// toujours `artiste - titre` — or bien des fichiers sont nommés
/// `titre - artiste`. La version nettoyée est alors essayée inversée aussi,
/// avant le titre seul. Pas quand un modèle a répondu : il déduit l'ordre
/// du sens.
///
/// Un champ deviné vide retombe sur la valeur utilisée. Une variante
/// identique à la requête déjà faite, ou à une variante précédente
/// (insensible à la casse et aux espaces), est sautée : jamais deux fois
/// la même requête. La liste peut être vide.
List<SearchVariant> buildSearchVariants({
  required String usedTitle,
  required String usedArtist,
  required String guessTitle,
  required String guessArtist,
  bool mayBeReversed = false,
}) {
  final fullTitle = guessTitle.trim().isNotEmpty ? guessTitle : usedTitle;
  final fullArtist = guessArtist.trim().isNotEmpty ? guessArtist : usedArtist;
  final cleanTitle = cleanSearchTitle(fullTitle);
  final cleanArtist = cleanSearchArtist(fullArtist);

  final seen = <String>{_key(usedTitle, usedArtist)};
  final variants = <SearchVariant>[];
  void add(String title, String artist) {
    if (title.trim().isEmpty) return;
    if (seen.add(_key(title, artist))) {
      variants.add((title: title, artist: artist));
    }
  }

  add(fullTitle, fullArtist);
  add(cleanTitle, cleanArtist);
  if (mayBeReversed && guessArtist.trim().isNotEmpty) {
    add(cleanSearchTitle(guessArtist), cleanSearchArtist(guessTitle));
  }
  add(cleanTitle, '');
  return variants;
}
