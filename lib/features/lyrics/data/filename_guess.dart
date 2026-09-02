/// Guesses an artist and a title out of a file name.
///
/// Tags are wrong often enough that the search screen needs a way to start from
/// the file name instead — and a library built from downloads is full of names
/// like `---Mr SAYDA  -  MBA MARINA ANIE (Official Vidéo 2017)-mc.mp3`.
///
/// The shapes are regular enough to unpick without asking anyone: strip the
/// decoration a downloader added, then split on the dash that separates the two
/// halves. What is left is a *guess*, offered in the fields for the user to
/// correct — never written to a file on its own.
library;

/// What a file name appears to say.
typedef FilenameGuess = ({String artist, String title});

abstract final class FilenameParser {
  /// Words that mark a bracketed group as decoration rather than part of the
  /// title.
  ///
  /// `(Official Vidéo 2017)` goes; `(ANATI Remix 2018)` stays, because a remix
  /// is genuinely part of what the track is called. That distinction is the
  /// whole reason this is a keyword list and not a rule about brackets.
  static const List<String> _junkWords = [
    'official',
    'officiel',
    'officielle',
    'video',
    'vidéo',
    'clip',
    'lyrics',
    'lyric',
    'paroles',
    'audio only',
    'hd',
    'hq',
    'full',
    'youtube',
    'mp3',
    'mp4',
    'download',
    'free',
    'new',
    'nouveaute',
    'nouveauté',
    'exclusive',
    'exclusivite',
    'exclusivité',
  ];

  /// Resolutions and bitrates: `(360P)`, `(MP3_160K)`, `[1080p]`.
  static final RegExp _qualityGroup = RegExp(
    r'^[\s_]*(?:mp3[\s_]*)?\d{3,4}\s*[pk](?:bps)?[\s_]*$',
    caseSensitive: false,
  );

  /// A bracketed or parenthesised run, kept lazy so `(a)(b)` is two groups.
  static final RegExp _bracketed = RegExp(r'[\(\[]([^\(\)\[\]]*)[\)\]]');

  /// Anything that is not a letter or a digit separates two words.
  ///
  /// Written out rather than leaning on `\b`, which in Dart is defined over
  /// `[A-Za-z0-9_]` — so there is no word boundary on either side of an `é`,
  /// and `\bnouveauté\b` can never match. Half these file names are French.
  static final RegExp _wordSplit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// Whether [text] contains one of [_junkWords] as a whole word.
  static bool _readsAsJunk(String text) {
    final words = text
        .toLowerCase()
        .split(_wordSplit)
        .where((w) => w.isNotEmpty)
        .toSet();
    return _junkWords.any(words.contains);
  }

  /// Leading track numbers: `01_`, `03 - `, `12.`
  static final RegExp _trackNumber = RegExp(r'^\s*\d{1,3}\s*[-_.\s]\s*');

  /// Trailing junk a downloader tacks on: `- YouTube`, `-mc`, a stray dash.
  static final RegExp _trailingJunk = RegExp(
    r'(?:\s*-\s*youtube|\s*-\s*mc|[\s\-_✅]+)$',
    caseSensitive: false,
  );

  /// Best guess at the artist and title behind [fileName].
  ///
  /// [fileName] may be a full path; only the last segment is looked at. Either
  /// half can come back empty when the name simply does not say — a bare
  /// `(Matsubara RN 13).mp3` has no artist in it, and inventing one would be
  /// worse than leaving the field for the user.
  static FilenameGuess parse(String fileName) {
    var text = _baseName(fileName);

    // `-u0026` is a mangled `&`, which is what a downloader leaves behind
    // when it writes an escaped ampersand out as literal text.
    text = text.replaceAll(RegExp(r'-?u0026'), '&');

    // Underscores stand in for spaces, but `_-_` is a separator in disguise.
    text = text.replaceAll('_-_', ' - ').replaceAll('_', ' ');

    text = _stripJunkGroups(text);
    text = text.replaceFirst(_trackNumber, '');
    // Leading dashes, of which these names have plenty: `- - - BASTA`.
    text = text.replaceFirst(RegExp(r'^[\s\-–—]+'), '');
    text = text.replaceFirst(_trailingJunk, '');
    text = _collapseSpaces(text);

    return _split(text);
  }

  static String _baseName(String path) {
    final cut = path.lastIndexOf(RegExp(r'[/\\]'));
    var name = cut < 0 ? path : path.substring(cut + 1);

    final dot = name.lastIndexOf('.');
    // Only a short trailing run is an extension; a dot inside a title is not.
    if (dot > 0 && name.length - dot <= 5) name = name.substring(0, dot);
    return name;
  }

  static String _stripJunkGroups(String text) {
    return text.replaceAllMapped(_bracketed, (match) {
      final inner = match.group(1) ?? '';
      if (_qualityGroup.hasMatch(inner)) return '';

      // Kept, brackets and all, when it says something about the music.
      return _readsAsJunk(inner) ? '' : match.group(0)!;
    });
  }

  static String _collapseSpaces(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Splits on the separating dash.
  ///
  /// The *first* dash surrounded by spaces, not any dash: `--Nael feat- Dj
  /// Mijay - BETINA` has a dash inside the artist, and splitting on it would
  /// hand back half a name. A bare `Titre` with no dash at all is a title with
  /// an unknown artist, which is honest — the file name really does not say.
  static FilenameGuess _split(String text) {
    final match = RegExp(r'\s+[-–—]\s+').firstMatch(text);
    if (match != null) {
      return (
        artist: _tidy(text.substring(0, match.start)),
        title: _dropTrailingJunkPhrase(_tidy(text.substring(match.end))),
      );
    }

    // No separator. A name that opens with a bracketed group and carries on is
    // conventionally `(artist) title` — `(DRAGIN D' Ihosy ) JANGOBO`.
    final leading = RegExp(
      r'^[\(\[]([^\(\)\[\]]+)[\)\]]\s*(.+)$',
    ).firstMatch(text);
    if (leading != null) {
      final rest = _tidy(leading.group(2)!);
      if (rest.isNotEmpty) {
        return (artist: _tidy(leading.group(1)!), title: rest);
      }
    }

    // Nothing to split on: a title whose artist the name simply does not give.
    return (artist: '', title: _dropTrailingJunkPhrase(_tidy(text)));
  }

  /// Drops a trailing `-Nouveauté 2019` — decoration that never made it into
  /// brackets, so [_stripJunkGroups] could not see it.
  ///
  /// Only the run after the final dash, and only when it reads as junk:
  /// `BHERINDR - DEE ANDRIAMBELO` must survive intact.
  static String _dropTrailingJunkPhrase(String title) {
    final cut = title.lastIndexOf(RegExp(r'[-–—]'));
    if (cut <= 0) return title;

    return _readsAsJunk(title.substring(cut + 1))
        ? _tidy(title.substring(0, cut))
        : title;
  }

  /// Trims the punctuation left at an edge once a group has been removed.
  static String _tidy(String part) => _collapseSpaces(
    part.replaceAll(RegExp(r'^[\s\-–—_.,]+|[\s\-–—_.,]+$'), ''),
  );
}
