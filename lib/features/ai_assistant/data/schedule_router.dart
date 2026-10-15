import 'dart:convert';

/// Routeur déterministe pré-modèle pour la planification de lecture.
///
/// Détecte « verbe de lecture + heure future » (ex. « lance la musique à
/// 4h43 ») et renvoie directement le plan JSON `schedule_once`, sans passer
/// par le modèle — dont les descriptions d'outils attiraient ce motif vers
/// `cancel_scheduled_action` (l'exemple « 22h » de sa description).
///
/// Le JSON produit est identique à celui du modèle : il passe par `parsePlan`
/// puis `executePlan` comme d'habitude (mêmes validations, mêmes garde-fous).

/// Nom de l'outil de lecture à planifier. Sans « query », `play` reprend
/// simplement la lecture en cours.
const _playToolName = 'play';

// Heure : « à 4h43 », « 22h », « 7h05 », « 22 h 30 », « 04:43 », « à 4 heures 43 ».
// Groupes : 1 = « à », 2 = heure, 3 = minutes (format h), 4 = minutes (format :).
final _timeRe = RegExp(
  r'(?:(à)\s*)?(?<![\d:])(\d{1,2})'
  r'(?:\s*(?:heures?|h)(?![a-zà-ÿ])\s*(\d{2})?|:(\d{2}))(?![\d:])',
);

final _tokenSplitRe = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

// Verbes de démarrage (lancer, jouer, démarrer, planifier, programmer).
final _verbRe = RegExp(
  r'^(?:lanc\w*|jou(?:e|es|er|ez)|d[ée]marr\w*|planifi\w*|programm\w*)$',
);

// Préfixes d'annulation : si un seul mot commence ainsi, on ne route JAMAIS.
const _cancelPrefixes = [
  'annul',
  'supprim',
  'désactiv',
  'desactiv',
  'stop',
  'arrêt',
  'arret',
  'efface',
  'retir',
  'enlev',
];

// Mots neutres autorisés autour de « lance la musique à 4h43 ».
const _fillers = {
  'la',
  'le',
  'les',
  'ma',
  'mon',
  'de',
  'du',
  'des',
  'un',
  'une',
  'moi',
  'me',
  's',
  'il',
  'te',
  'plait',
  'plaît',
  'stp',
  'svp',
  'peux',
  'tu',
  'pourrais',
  'pour',
  'et',
  'alors',
  'merci',
  'à',
  'demain',
  'musique',
  'lecture',
  'son',
};

/// Détecte « verbe de lecture + heure future » et renvoie directement le plan
/// JSON `schedule_once` ; sinon `null` (le modèle décide).
///
/// Fonction pure : [now] est injectable pour les tests.
String? routeScheduledPlay(String text, {DateTime? now}) {
  final t = text.toLowerCase().trim();
  if (t.isEmpty) return null;
  final clock = now ?? DateTime.now();

  final tokens = t.split(_tokenSplitRe).where((s) => s.isNotEmpty).toList();

  // 1. Jamais d'interception d'une annulation.
  for (final tok in tokens) {
    if (_cancelPrefixes.any(tok.startsWith)) return null;
  }

  // 2. Exactement une heure, avec « à » (ou format 04:43).
  final matches = _timeRe.allMatches(t).toList();
  if (matches.length != 1) return null;
  final m = matches.single;
  if (m.group(1) == null && m.group(4) == null) return null;

  final hour = int.parse(m.group(2)!);
  final minute = int.parse(m.group(3) ?? m.group(4) ?? '0');
  if (hour > 23 || minute > 59) return null;

  // 3. Le reste de la phrase doit être « verbe + musique/lecture » rien d'autre
  //    (pas de contenu précis, pas de « tous les jours », « ce soir », etc.).
  final rest = t.replaceRange(m.start, m.end, ' ');
  final restTokens =
      rest.split(_tokenSplitRe).where((s) => s.isNotEmpty).toList();

  var hasVerb = false;
  var hasNoun = false;
  for (final tok in restTokens) {
    if (_verbRe.hasMatch(tok)) {
      hasVerb = true;
    } else if (_fillers.contains(tok)) {
      if (tok == 'musique' || tok == 'lecture') hasNoun = true;
    } else {
      return null; // mot inconnu → on laisse le modèle décider
    }
  }
  if (!hasVerb || !hasNoun) return null;

  // 4. Calcul de la date : « demain » explicite, sinon prochaine occurrence
  //    (heure déjà passée → lendemain, comme une alarme classique).
  var target = DateTime(clock.year, clock.month, clock.day, hour, minute);
  if (restTokens.contains('demain') || !target.isAfter(clock)) {
    target = DateTime(clock.year, clock.month, clock.day + 1, hour, minute);
  }

  return _buildPlan(target, hour, minute);
}

String _two(int n) => n.toString().padLeft(2, '0');

String _buildPlan(DateTime target, int hour, int minute) {
  final iso = '${target.year}-${_two(target.month)}-${_two(target.day)}'
      'T${_two(hour)}:${_two(minute)}';
  return jsonEncode({
    'tool': 'schedule_once',
    'args': {
      'datetime': iso,
      'tool': _playToolName,
      'args': <String, dynamic>{},
      'label': 'Lecture à ${hour}h${_two(minute)}',
    },
  });
}
