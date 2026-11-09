/// Score de confiance d'un candidat paroles — fonction pure, testable.
///
/// Un seul scoreur pour tous les chemins (IA, fond, lot) : la confiance ne
/// fait plus que trier, elle filtre. Voir DESIGN.md §3.
///
/// Poids : titre 0,35 + artiste 0,30 + album 0,05 + durée 0,15 + synchro
/// 0,05 + accord nom de fichier 0,10 − pénalité placeholder 0,30.
/// Aucun plancher : sans aucun champ concordant, le score est 0 (plus le
/// bonus synchro seul) — le plancher 0,30 de l'ancien `_score` couronnait
/// des faux hits à 0,35.
library;

import 'package:musync/core/utils/text_search.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';

/// Seuil unique, partagé avec le lot (`BatchCandidate` y fait référence).
///
/// ≥ 0,80 : intégration automatique. 0,50–0,79 : proposition à
/// l'utilisateur. En dessous de 0,50 : rien n'est écrit.
abstract final class LyricsConfidence {
  static const double autoIntegrateConfidence = 0.80;
  static const double proposeConfidence = 0.50;

  static const double _titleExact = 0.35;
  static const double _titlePartial = 0.15;
  static const double _artistExact = 0.30;
  static const double _artistPartial = 0.15;
  static const double _albumExact = 0.05;
  static const double _durationClose = 0.15;
  static const double _durationLoose = 0.07;
  static const double _syncedBonus = 0.05;
  static const double _filenameAgreement = 0.10;
  static const double _placeholderPenalty = 0.30;

  /// Tolérances de durée, les mêmes que l'ancien `_durationToleranceMs`.
  static const int durationCloseMs = 3000;
  static const int durationLooseMs = 10000;
}

/// Le détail d'un score, pour l'UI et le Journal.
class LyricsConfidenceScore {
  final double total;
  final double title;
  final double artist;
  final double album;
  final double duration;
  final double synced;
  final double filenameAgreement;
  final double placeholderPenalty;

  const LyricsConfidenceScore({
    required this.total,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.synced,
    required this.filenameAgreement,
    required this.placeholderPenalty,
  });

  /// Vrai quand le candidat peut être intégré seul.
  bool get autoIntegrate => total >= LyricsConfidence.autoIntegrateConfidence;

  /// Vrai quand le candidat vaut d'être proposé à l'utilisateur.
  bool get worthProposing => total >= LyricsConfidence.proposeConfidence;
}

/// Normalise pour la comparaison : minuscules, accents pliés, ponctuation
/// et espaces réduits à un seul séparateur.
String normalizeForConfidence(String text) => foldForSearch(text)
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Vrai quand [value] est un placeholder, pas un nom — « Artiste inconnu »,
/// `« <unknown> »`, « Track 01 », « Untitled », …
bool isPlaceholderLyricsText(String value) {
  final folded = normalizeForConfidence(value);
  if (folded.isEmpty) return true;
  const placeholders = {
    'unknown',
    'inconnu',
    'inconnue',
    'untitled',
    'sans titre',
    'titre inconnu',
    'artiste inconnu',
    'album inconnu',
    'unknown artist',
    'unknown title',
    'unknown album',
    '<unknown>',
  };
  if (placeholders.contains(folded)) return true;
  // « Track 01 », « Piste 12 », « Track 1 » : un numéro de piste, pas un titre.
  // Le numéro est obligatoire : « Titre » seul peut être un vrai titre.
  return RegExp(r'^(track|piste|titre|title)\s*\d{1,3}$').hasMatch(folded);
}

/// Retire les groupes entre parenthèses/crochets en fin de titre
/// (« (feat. X) », « (Remix) », « [Remastered] »), pour comparer le titre
/// nu. Les groupes au milieu sont conservés : ils font partie du titre.
String _stripTrailingGroups(String normalized) {
  var out = normalized;
  while (true) {
    final cut = out.replaceFirst(RegExp(r'\s*[\(\[][^\(\)\[\]]*[\)\]]\s*$'), '');
    if (cut == out) return out;
    out = cut;
  }
}

/// La base d'un nom d'artiste : « A feat. B » vaut pour A.
String _artistBase(String normalized) {
  final cut = normalized.indexOf(RegExp(r'\b(feat|ft|featuring)\b'));
  return (cut < 0 ? normalized : normalized.substring(0, cut)).trim();
}

bool _titleExact(String candidate, String query) {
  if (candidate.isEmpty || query.isEmpty) return false;
  return candidate == query;
}

bool _titlePartial(String candidate, String query) {
  if (candidate.isEmpty || query.isEmpty) return false;
  if (candidate.contains(query) || query.contains(candidate)) return true;
  return _stripTrailingGroups(candidate) == _stripTrailingGroups(query);
}

bool _artistExact(String candidate, String query) {
  if (candidate.isEmpty || query.isEmpty) return false;
  if (candidate == query) return true;
  final baseC = _artistBase(candidate);
  final baseQ = _artistBase(query);
  return baseC.isNotEmpty && baseC == baseQ;
}

bool _artistPartial(String candidate, String query) {
  if (candidate.isEmpty || query.isEmpty) return false;
  return candidate.contains(query) || query.contains(candidate);
}

/// Score un candidat LRCLIB contre la requête qui l'a produit.
///
/// [filenameGuess] est la devinette tirée du nom de fichier, quand elle
/// existe : un candidat qui lui correspond gagne +0,10.
LyricsConfidenceScore scoreLyricsCandidate({
  required String candidateTitle,
  required String candidateArtist,
  String? candidateAlbum,
  int? candidateDurationMs,
  required bool candidateHasSynced,
  required String queryTitle,
  required String queryArtist,
  String? queryAlbum,
  int? queryDurationMs,
  FilenameGuess? filenameGuess,
}) {
  final cTitle = normalizeForConfidence(candidateTitle);
  final qTitle = normalizeForConfidence(queryTitle);
  final cArtist = normalizeForConfidence(candidateArtist);
  final qArtist = normalizeForConfidence(queryArtist);

  var title = 0.0;
  if (_titleExact(cTitle, qTitle)) {
    title = LyricsConfidence._titleExact;
  } else if (_titlePartial(cTitle, qTitle)) {
    title = LyricsConfidence._titlePartial;
  }

  var artist = 0.0;
  if (_artistExact(cArtist, qArtist)) {
    artist = LyricsConfidence._artistExact;
  } else if (_artistPartial(cArtist, qArtist)) {
    artist = LyricsConfidence._artistPartial;
  }

  var album = 0.0;
  final cAlbum = normalizeForConfidence(candidateAlbum ?? '');
  final qAlbum = normalizeForConfidence(queryAlbum ?? '');
  if (cAlbum.isNotEmpty && qAlbum.isNotEmpty && cAlbum == qAlbum) {
    album = LyricsConfidence._albumExact;
  }

  var duration = 0.0;
  if (candidateDurationMs != null &&
      queryDurationMs != null &&
      queryDurationMs > 0) {
    final delta = (candidateDurationMs - queryDurationMs).abs();
    if (delta <= LyricsConfidence.durationCloseMs) {
      duration = LyricsConfidence._durationClose;
    } else if (delta <= LyricsConfidence.durationLooseMs) {
      duration = LyricsConfidence._durationLoose;
    }
  }

  final synced =
      candidateHasSynced ? LyricsConfidence._syncedBonus : 0.0;

  var filenameAgreement = 0.0;
  final guess = filenameGuess;
  if (guess != null) {
    final gTitle = normalizeForConfidence(guess.title);
    final gArtist = normalizeForConfidence(guess.artist);
    if (gTitle.isNotEmpty &&
        gArtist.isNotEmpty &&
        _titleExact(cTitle, gTitle) &&
        _artistExact(cArtist, gArtist)) {
      filenameAgreement = LyricsConfidence._filenameAgreement;
    }
  }

  var placeholderPenalty = 0.0;
  if (isPlaceholderLyricsText(candidateTitle) ||
      isPlaceholderLyricsText(candidateArtist)) {
    placeholderPenalty = -LyricsConfidence._placeholderPenalty;
  }

  final total =
      ((title +
                  artist +
                  album +
                  duration +
                  synced +
                  filenameAgreement +
                  placeholderPenalty)
              .clamp(0.0, 1.0) *
          1000)
      .round() /
      1000;

  return LyricsConfidenceScore(
    total: total,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    synced: synced,
    filenameAgreement: filenameAgreement,
    placeholderPenalty: placeholderPenalty,
  );
}

/// La devinette nom de fichier contredit-elle la requête tags ?
///
/// Vrai quand la devinette donne un titre ou un artiste non vide qui
/// diffère de la requête (après pliage). Un `/get` à 1,0 sur des tags
/// faux ne doit plus être une certitude dans ce cas : il est plafonné
/// à 0,80.
bool filenameGuessContradictsQuery(
  FilenameGuess? guess, {
  required String queryTitle,
  required String queryArtist,
}) {
  if (guess == null) return false;
  final gTitle = normalizeForConfidence(guess.title);
  final gArtist = normalizeForConfidence(guess.artist);
  if (gTitle.isNotEmpty && gTitle != normalizeForConfidence(queryTitle)) {
    return true;
  }
  if (gArtist.isNotEmpty && gArtist != normalizeForConfidence(queryArtist)) {
    return true;
  }
  return false;
}
