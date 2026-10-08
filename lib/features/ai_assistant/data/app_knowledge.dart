/// Base de connaissances curée : les fiches d'aide VÉRIFIÉES de Musync.
///
/// `app_help` cherche par mots-clés dans ces fiches et retourne la fiche telle
/// quelle. Le modèle ne doit JAMAIS générer librement une procédure : le
/// prompt système l'exige — une hallucination a déjà été constatée sur
/// appareil (« va dans Paramètres › Interface/Affichage », des sections qui
/// n'existent pas).
///
/// Tout le texte est en français, relu contre l'app réelle. Quand l'app
/// change, c'est ici qu'on met à jour — pas dans un prompt.
library;

import 'package:musync/core/utils/text_search.dart';

/// Une fiche d'aide : mots-clés de recherche + texte vérifié.
class HelpArticle {
  final Set<String> keywords;
  final String text;

  const HelpArticle({required this.keywords, required this.text});
}

const List<HelpArticle> appKnowledge = [
  HelpArticle(
    keywords: {
      'bulle', 'flottante', 'overlay', 'superposition', 'flottant',
      'activer', 'désactiver',
    },
    text: 'La bulle flottante s’active en UN TAP depuis l’écran « Lecture en '
        'cours » (le bouton bulle) — il n’y a rien à autoriser dans les '
        'réglages de Musync, il n’y a ni section « Interface » ni '
        '« Affichage ». Elle ne s’affiche que par-dessus les AUTRES applis, '
        'jamais dans Musync — dans l’app, la ligne de parole courante '
        'apparaît sous la barre de progression du mini-lecteur. Tu peux '
        'aussi me demander de l’activer ou la désactiver.',
  ),
  HelpArticle(
    keywords: {
      'caler', 'calage', 'synchroniser', 'synchro', 'éditeur', 'rythme',
      'taper',
    },
    text: 'Pour caler des paroles : ouvre le morceau, appui long sur une '
        'ligne de paroles, « Caler », puis tape chaque ligne au rythme de la '
        'musique dans l’éditeur de synchro. L’IA ne peut pas caler à ta '
        'place : elle ne peut pas écouter.',
  ),
  HelpArticle(
    keywords: {
      'refresh', 'rafraîchir', 'tirer', 'rescan', 'recharger', 'analyser',
      'musicolet',
    },
    text: 'Tire la liste de la bibliothèque vers le bas (pull-to-refresh) : '
        'ça relance l’analyse — tags et paroles sont relus depuis les '
        'fichiers. C’est la seule façon de forcer Musync à reprendre des '
        'modifications faites par un autre lecteur (ex. Musicolet).',
  ),
  HelpArticle(
    keywords: {
      'source', 'lrclib', 'api', 'paroles', 'trouver', 'chercher paroles',
    },
    text: 'Les paroles viennent des sources de l’onglet Sources (Paramètres '
        '› Sources) : LRCLIB par défaut, plus tes propres instances '
        'auto-hébergées ou miroirs compatibles avec son API. Le collage '
        'direct garde le texte exactement tel quel.',
  ),
  HelpArticle(
    keywords: {
      'file', 'queue', 'playlist', 'liste de lecture',
    },
    text: 'Les files nommées se créent depuis une recherche : cherche un '
        'artiste ou un titre, puis « Créer une file ». Tu peux aussi me '
        'demander : « fais une file avec tout Niska ».',
  ),
  HelpArticle(
    keywords: {
      'minuteur', 'timer', 'arrêt', 'dodo', 'sleep', 'dormir',
    },
    text: 'Le minuteur d’arrêt est dans l’écran « Lecture en cours » — ou '
        'demande-moi : « minuteur 20 min ». La lecture s’arrête au bout du '
        'délai.',
  ),
  HelpArticle(
    keywords: {
      'journal', 'log', 'diagnostic', 'debug',
    },
    text: 'Le Journal (diagnostic) s’affiche par appui long sur le titre '
        '« Paramètres ». C’est là que Musync écrit ce qu’il fait : recherches '
        'de paroles, écritures de tags, erreurs.',
  ),
  HelpArticle(
    keywords: {
      'exclure', 'exclus', 'exclusion', 'dossier', 'dossiers', 'cacher',
      'ignorer',
    },
    text: 'Paramètres › Bibliothèque : les « Dossiers exclus » et « Fichiers '
        'exclus » sont sautés par le scan. Tu peux aussi me demander : '
        '« exclus ce morceau » (le fichier seul) ou « exclus ce dossier » '
        '(tout le dossier).',
  ),
  HelpArticle(
    keywords: {
      'commande', 'assistant', 'aide', 'help', 'savoir faire', 'que sais-tu',
    },
    text: 'Je me pilote depuis la barre de recherche avec « ! » devant : '
        '« !mets en pause », « !joue du Juice », « !récupère les paroles », '
        '« !minuteur 20 min », « !tous les jours à 22h, minuteur 30 min », '
        '« !quand je branche mes écouteurs, lance ma file Nuit ».',
  ),
];

/// La fiche dont le plus de mots-clés apparaissent dans [question].
///
/// Pliage insensible aux accents et à la casse, comme la recherche de la
/// bibliothèque. Null si aucun mot-clé ne matche — l'appelant répond alors
/// honnêtement qu'il ne sait pas, au lieu d'inventer.
HelpArticle? findHelpArticle(String question) {
  final folded = foldForSearch(question);
  if (folded.trim().isEmpty) return null;
  HelpArticle? best;
  var bestScore = 0;
  for (final article in appKnowledge) {
    var score = 0;
    for (final keyword in article.keywords) {
      if (folded.contains(foldForSearch(keyword))) score++;
    }
    if (score > bestScore) {
      bestScore = score;
      best = article;
    }
  }
  return best;
}
