/// Résolution d'identité partagée : tags nettoyés → heuristique nom de
/// fichier → LLM → double requête en cas de désaccord (DESIGN.md §4).
///
/// Un seul résolveur pour l'IA, le fond et le lot : la même question ne
/// donne plus trois réponses différentes selon le chemin qui la pose.
/// Il ne cherche pas lui-même : il prépare les requêtes, le service
/// cherche.
library;

import 'package:musync/core/utils/text_search.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_confidence.dart';

/// D'où vient une requête.
enum LyricsQueryOrigin {
  /// Les tags du fichier, nettoyés des placeholders.
  tags,

  /// Le nom de fichier (heuristique ou LLM).
  filename,

  /// Le LLM, quand heuristique et tags ne suffisent pas ou se contredisent.
  ai,
}

/// Une requête prête à partir : titre + artiste, jamais vides.
class LyricsQuery {
  final String title;
  final String artist;
  final String? album;
  final LyricsQueryOrigin origin;

  const LyricsQuery({
    required this.title,
    required this.artist,
    this.album,
    required this.origin,
  });

  /// La même question, après pliage ? Deux requêtes identiques ne
  /// partent jamais deux fois.
  bool sameAs(LyricsQuery other) =>
      foldForSearch(title) == foldForSearch(other.title) &&
      foldForSearch(artist) == foldForSearch(other.artist);

  @override
  String toString() => 'LyricsQuery($title — $artist, $origin)';
}

/// Ce que le résolveur rend : la ou les requêtes, leur origine, et la
/// devinette nom de fichier (pour le bonus d'accord du scoreur).
class ResolvedLyricsQueries {
  /// Une ou deux requêtes. Deux seulement en cas de désaccord tags ≠ nom
  /// de fichier — et jamais deux fois la même.
  final List<LyricsQuery> queries;

  /// La devinette tirée du nom de fichier (heuristique, ou LLM quand il
  /// a répondu), null quand le nom ne dit rien.
  final FilenameGuess? filenameGuess;

  /// Vrai quand la requête principale est de bonne qualité (titre non
  /// vide, pas de placeholder) : seul un « rien trouvé » sur une bonne
  /// requête mérite d'être cru 14 jours par SweepMemory.
  final bool goodQuality;

  const ResolvedLyricsQueries({
    required this.queries,
    required this.filenameGuess,
    required this.goodQuality,
  });

  LyricsQuery get primary => queries.first;
}

/// Résout l'identité d'un morceau avant toute recherche de paroles.
class LyricsQueryResolver {
  /// L'heuristique hors ligne (gratuite). Injectée pour les tests.
  final FilenameGuess Function(String filePath) parseFilename;

  /// Un appel LLM : lit artiste/titre dans le nom du fichier, ou null
  /// quand aucun modèle n'est disponible. Null = pas de LLM (balayage
  /// headless, tests sans réseau).
  final Future<FilenameGuess?> Function(String fileName)? readWithAi;

  const LyricsQueryResolver({
    this.parseFilename = FilenameParser.parse,
    this.readWithAi,
  });

  /// Résout les requêtes pour [song].
  ///
  /// [aiFallback] autorise le LLM. Faux pour le balayage headless : pas
  /// de quota brûlé la nuit, le résolveur s'arrête à l'heuristique.
  Future<ResolvedLyricsQueries> resolve(
    Song song, {
    bool aiFallback = true,
  }) async {
    // 1. Tags nettoyés : un placeholder n'est pas un terme de recherche.
    var title = _cleanTag(song.title);
    var artist = _cleanTag(song.artist);
    final album = _cleanTag(song.album);
    final tagsComplete = title.isNotEmpty && artist.isNotEmpty;

    // 2. Heuristique nom de fichier — hors ligne, gratuite.
    final guess = parseFilename(song.filePath);
    final guessUseful =
        guess.title.trim().isNotEmpty || guess.artist.trim().isNotEmpty;

    FilenameGuess? aiGuess;
    Future<FilenameGuess?> askAi() async {
      final reader = readWithAi;
      if (!aiFallback || reader == null) return null;
      final fileName = song.filePath.split(RegExp(r'[/\\]')).last;
      try {
        return await reader(fileName);
      } catch (_) {
        return null;
      }
    }

    // 1+2. Tags nettoyés, puis heuristique pour combler les trous. Les
    // tags priment champ par champ : un titre taggé « 09 » reste « 09 »
    // dans la requête principale, même si le nom de fichier dit mieux —
    // c'est la seconde requête ci-dessous qui portera la devinette.
    if (title.isEmpty) title = guess.title.trim();
    if (artist.isEmpty) artist = guess.artist.trim();
    if (title.isEmpty || artist.isEmpty) {
      // 3. Le LLM, seulement si 1+2 laissent un champ vide.
      aiGuess = await askAi();
      final ai = aiGuess;
      if (ai != null) {
        if (title.isEmpty) title = ai.title.trim();
        if (artist.isEmpty) artist = ai.artist.trim();
      }
    }
    if (title.isEmpty || artist.isEmpty) {
      // Rien d'exploitable nulle part : pas de requête. Une recherche
      // aveugle vaut moins que pas de recherche.
      return ResolvedLyricsQueries(
        queries: const [],
        filenameGuess: _nonEmptyGuess(aiGuess ?? guess),
        goodQuality: false,
      );
    }
    final primary = LyricsQuery(
      title: title,
      artist: artist,
      album: album.isEmpty ? null : album,
      origin: tagsComplete
          ? LyricsQueryOrigin.tags
          : LyricsQueryOrigin.filename,
    );
    final queries = [primary];

    // 4. Désaccord avec le nom de fichier → deux requêtes. C'est le cas
    // des tags faux (« 09 ») : la requête tags part quand même, mais la
    // devinette part aussi, et le meilleur score gagne. Le LLM arbitre
    // quand il est disponible : sa devinette remplace celle de
    // l'heuristique comme seconde requête ; sinon l'heuristique suffit,
    // gratuite et souvent juste.
    if (guessUseful && _differs(guess, title, artist)) {
      aiGuess ??= await askAi();
      final challenger = aiGuess ?? guess;
      final second = _guessQuery(
        challenger,
        title,
        artist,
        origin: aiGuess != null
            ? LyricsQueryOrigin.ai
            : LyricsQueryOrigin.filename,
      );
      if (second != null && !second.sameAs(primary)) {
        queries.add(second);
      }
    }
    return ResolvedLyricsQueries(
      queries: queries,
      filenameGuess: _nonEmptyGuess(aiGuess ?? guess),
      goodQuality: _goodQuality(title, artist),
    );
  }

  /// Un placeholder n'est pas un terme de recherche — ni pour la requête,
  /// ni pour le jugement de sa qualité.
  static String _cleanTag(String value) {
    final trimmed = value.trim();
    if (MusicScanner.isUnknown(trimmed)) return '';
    if (isPlaceholderLyricsText(trimmed)) return '';
    return trimmed;
  }

  static bool _goodQuality(String title, String artist) =>
      title.isNotEmpty &&
      !isPlaceholderLyricsText(title) &&
      !isPlaceholderLyricsText(artist);

  /// La devinette diffère-t-elle de la requête tags (après pliage) ?
  static bool _differs(FilenameGuess guess, String title, String artist) {
    final gTitle = foldForSearch(guess.title.trim());
    final gArtist = foldForSearch(guess.artist.trim());
    if (gTitle.isNotEmpty && gTitle != foldForSearch(title)) return true;
    if (gArtist.isNotEmpty && gArtist != foldForSearch(artist)) return true;
    return false;
  }

  /// Une seconde requête depuis une devinette, complétée par les tags
  /// quand la devinette ne donne qu'un champ. Null quand elle n'apporte
  /// rien (devinette vide).
  static LyricsQuery? _guessQuery(
    FilenameGuess guess,
    String tagTitle,
    String tagArtist, {
    required LyricsQueryOrigin origin,
  }) {
    final title =
        guess.title.trim().isNotEmpty ? guess.title.trim() : tagTitle;
    final artist =
        guess.artist.trim().isNotEmpty ? guess.artist.trim() : tagArtist;
    if (title.isEmpty || artist.isEmpty) return null;
    return LyricsQuery(title: title, artist: artist, origin: origin);
  }

  static FilenameGuess? _nonEmptyGuess(FilenameGuess guess) =>
      guess.title.trim().isEmpty && guess.artist.trim().isEmpty
          ? null
          : guess;
}
