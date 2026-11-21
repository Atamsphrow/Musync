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
  ///
  /// Single words only: a group is split into words before the lookup, so a
  /// phrase here (the old `audio only`) could never match anything.
  static const List<String> _junkWords = [
    'official',
    'officiel',
    'officielle',
    'oficial',
    'video',
    'vidéo',
    'videoclip',
    'clip',
    'mv',
    'visualizer',
    'visualiser',
    'lyrics',
    'lyric',
    'paroles',
    'letra',
    'subtitulado',
    'legendado',
    'traduction',
    'audio',
    'hd',
    'hq',
    '4k',
    'uhd',
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

  /// The same, left bare at the end of the name by a converter:
  /// `…_v720P`, `… 320kbps`, `… HD`.
  static final RegExp _trailingQuality = RegExp(
    r'(?:\s+|-)(?:v?\d{3,4}p|\d{2,3}\s?k(?:bps)?|hd|hq|4k)$',
    caseSensitive: false,
  );

  /// A bracketed or parenthesised run, kept lazy so `(a)(b)` is two groups.
  static final RegExp _bracketed = RegExp(r'[\(\[]([^\(\)\[\]]*)[\)\]]');

  /// A web address a downloader stamped on the file: `y2mate.com`,
  /// `www.mp3juices.cc`. Never part of a title.
  static final RegExp _domain = RegExp(
    r'(?:https?://)?(?:www\.)?[a-z0-9][a-z0-9-]*\.'
    r'(?:com|net|org|cc|io|to|me|fm|info|biz|co|tv|ws|ch|app|site|online|xyz)'
    r'(?![a-z0-9])',
    caseSensitive: false,
  );

  /// A leading `y2mate.com - `, `[www.site.com] `: the site, then the name.
  static final RegExp _leadingDomain = RegExp(
    r'^\s*[\(\[]?\s*(?:https?://)?(?:www\.)?[a-z0-9][a-z0-9-]*\.'
    r'(?:com|net|org|cc|io|to|me|fm|info|biz|co|tv|ws|ch|app|site|online|xyz)'
    r'\s*[\)\]]?\s*[-–—_|:]*\s*',
    caseSensitive: false,
  );

  /// A YouTube video id, as yt-dlp appends it: `[dQw4w9WgXcQ]`, or
  /// `-dQw4w9WgXcQ` at the very end. Matched before underscores become
  /// spaces: an id may contain them.
  static final RegExp _bracketedId = RegExp(r'\s*\[([A-Za-z0-9_-]{11})\]');
  static final RegExp _trailingId = RegExp(r'-([A-Za-z0-9_-]{11})$');

  /// Whether [text] reads as a random video id rather than a word: an
  /// eleven-letter word in brackets (`[Instrumenta]`) must survive.
  static bool _looksLikeVideoId(String text) {
    if (RegExp(r'\d').hasMatch(text)) return true;
    if (RegExp(r'[_-]').hasMatch(text.substring(1))) return true;
    // A lower-case letter followed by a capital: `dQwAbcdEfgh`, never a
    // word in title case.
    return RegExp(r'[a-z][A-Z]').hasMatch(text);
  }

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

  /// Leading track numbers: `01_`, `03 - `, `12.`, `1-01 `, `Track 05 - `.
  ///
  /// A number followed by a mere space is a track number only when it is
  /// zero-padded (`01 Titre`): `7 Rings`, `3 Doors Down` and `50 Cent` are
  /// names that start with a number, and the old rule cut them down to
  /// `Rings`, `Doors Down` and `Cent`.
  static final RegExp _trackNumber = RegExp(
    r'^\s*(?:'
    r'(?:track|piste)\s*\d{1,3}\s*[-_.)]?\s+|'
    r'\d{1,2}[-.]\d{2,3}\s+|'
    r'\d{1,3}\s*[-_.)]\s*|'
    r'0\d{1,2}\s+'
    r')',
    caseSensitive: false,
  );

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
  static FilenameGuess parse(String fileName) =>
      _split(_clean(_baseName(fileName)));

  /// [text] without what a downloader added — junk groups, video ids,
  /// sites, resolutions, a leading track number, underscores — but not
  /// split: a tag value can be checked against it (see
  /// `tagTitleNeedsGuess`). A text with none of it comes back unchanged,
  /// spacing aside.
  static String stripDecoration(String text) => _clean(text);

  static String _clean(String raw) {
    var text = raw;

    // Video ids first, while their underscores are still underscores.
    text = text.replaceAllMapped(
      _bracketedId,
      (m) => _looksLikeVideoId(m.group(1)!) ? '' : m.group(0)!,
    );
    text = text.replaceFirstMapped(
      _trailingId,
      (m) => _looksLikeVideoId(m.group(1)!) ? '' : m.group(0)!,
    );

    // `-u0026` is a mangled `&`, which is what a downloader leaves behind
    // when it writes an escaped ampersand out as literal text.
    text = text.replaceAll(RegExp(r'-?u0026'), '&');

    // Underscores stand in for spaces, but `_-_` is a separator in disguise.
    text = text.replaceAll('_-_', ' - ').replaceAll('_', ' ');

    text = text.replaceFirst(_leadingDomain, '');
    text = _stripJunkGroups(text);
    text = text.replaceFirst(_trackNumber, '');
    // Leading dashes, of which these names have plenty: `- - - BASTA`.
    text = text.replaceFirst(RegExp(r'^[\s\-–—]+'), '');
    // A site left at the end: `… - y2mate.com`.
    text = text.replaceFirst(
      RegExp(r'\s*[-–—|]\s*' + _domain.pattern + r'\s*$', caseSensitive: false),
      '',
    );
    text = text.replaceFirst(_trailingQuality, '');
    text = text.replaceFirst(_trailingJunk, '');
    return _collapseSpaces(text);
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
      if (_domain.hasMatch(inner)) return '';

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
  /// hand back half a name. An en or em dash needs no spaces (`Artist–Title`):
  /// unlike the hyphen, no name carries one (`Jay-Z`, `A-ha`). A bare `Titre`
  /// with no dash at all is a title with an unknown artist, which is honest —
  /// the file name really does not say.
  static FilenameGuess _split(String text) {
    final match =
        RegExp(r'\s+[-–—]\s+').firstMatch(text) ??
        RegExp(r'\s*[–—]\s*').firstMatch(text);
    if (match != null && match.start > 0) {
      return (
        artist: _unquote(_tidy(text.substring(0, match.start))),
        title: _unquote(
          _dropTrailingJunkPhrase(_titleHalf(text.substring(match.end))),
        ),
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
        return (artist: _tidy(leading.group(1)!), title: _unquote(rest));
      }
    }

    // `Rick Astley "Never Gonna Give You Up"`: the quoted part is the title,
    // what comes before it the artist. Double quotes and guillemets only —
    // a single quote is far more often an apostrophe.
    final quoted = RegExp(
      r'^(.+?)\s+["“«]\s*([^"“”«»]+?)\s*["”»]\s*'
      r'((?:[\(\[][^\(\)\[\]]*[\)\]]\s*)*)$',
    ).firstMatch(text);
    if (quoted != null) {
      return (
        artist: _tidy(quoted.group(1)!),
        // A kept group after the quotes (`(Live)`) still belongs to it.
        title: _tidy('${quoted.group(2)!} ${quoted.group(3)!}'),
      );
    }

    // Nothing to split on: a title whose artist the name simply does not give.
    return (artist: '', title: _unquote(_dropTrailingJunkPhrase(_tidy(text))));
  }

  /// The title side of `artist - …`, without the track number some names
  /// carry there: `Artist - 01. Title`, `Artist - Album - 03 - Title`.
  static String _titleHalf(String text) {
    var title = _tidy(text);
    final segments = title.split(RegExp(r'\s+[-–—]\s+'));
    if (segments.length > 1) {
      // The title is what follows the last segment that is only a number.
      for (var i = segments.length - 2; i >= 0; i--) {
        if (RegExp(r'^\d{1,3}$').hasMatch(segments[i].trim())) {
          final rest = _tidy(segments.sublist(i + 1).join(' - '));
          if (rest.isNotEmpty) title = rest;
          break;
        }
      }
    }
    final unnumbered = _tidy(title.replaceFirst(_trackNumber, ''));
    return unnumbered.isEmpty ? title : unnumbered;
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

  /// `"Title"`, `« Title »`, `'Title'` → `Title`, when the quotes wrap the
  /// whole half and nothing else.
  static String _unquote(String part) {
    final match = RegExp(
      r'''^(["“«'‘])\s*(.+?)\s*(["”»'’])$''',
    ).firstMatch(part);
    if (match == null) return part;
    const pairs = {'"': '"', '“': '”', '«': '»', "'": "'", '‘': '’'};
    if (pairs[match.group(1)] != match.group(3)) return part;
    final inner = match.group(2)!;
    // `"Hello" and "Goodbye"` is two quoted runs, not one wrapped title.
    if (RegExp(r'''["“”«»]''').hasMatch(inner)) return part;
    return inner;
  }

  /// Trims the punctuation left at an edge once a group has been removed.
  static String _tidy(String part) => _collapseSpaces(
    part.replaceAll(RegExp(r'^[\s\-–—_.,|]+|[\s\-–—_.,|]+$'), ''),
  );
}

/// [ai]'s answer, with a field it left empty taken from [heuristic] — a model
/// unsure of the artist leaves it blank, while `ALG - Biloo` plainly says it.
///
/// Never when the heuristic's value is what the model put in the *other*
/// field: a model that read the name the other way round (`Title - Artist`)
/// must not end up with the artist twice.
FilenameGuess completeGuess(FilenameGuess ai, FilenameGuess heuristic) {
  String fold(String s) => s.trim().toLowerCase();
  var title = ai.title.trim();
  var artist = ai.artist.trim();
  final hTitle = heuristic.title.trim();
  final hArtist = heuristic.artist.trim();
  if (title.isEmpty && hTitle.isNotEmpty && fold(hTitle) != fold(artist)) {
    title = hTitle;
  }
  if (artist.isEmpty && hArtist.isNotEmpty && fold(hArtist) != fold(title)) {
    artist = hArtist;
  }
  return (artist: artist, title: title);
}
