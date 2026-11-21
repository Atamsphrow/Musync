/// What the lyrics search screen puts in its fields before searching: the
/// file's tags, unless a tag is plainly not a name — then the file name's
/// guess (see [FilenameParser]), or the tag cleaned of its decoration.
///
/// The screen used to replace every tag by the file name's guess, on the
/// grounds that a library of downloads has bad tags. A well-tagged one paid
/// for it: `Bohemian Rhapsody` / `Queen` became `Bohemian Rhapsody
/// (Remastered 2011)` from the file name, which the exact sources do not
/// find. The tags now win unless they are unknown, a placeholder, the raw
/// file name, or carry a downloader's decoration — the same « tags first,
/// field by field » rule as `LyricsQueryResolver`. The guess still gets its
/// turn in the automatic second attempt.
///
/// Pure functions, no Flutter: tested as they are.
library;

import 'package:musync/core/utils/text_search.dart';
import 'package:musync/features/library/data/music_scanner.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_confidence.dart';

String _fold(String text) => normalizeForConfidence(text);

/// Lighter than [_fold]: case and spacing only, so an underscore or a
/// stray dash still counts as a difference.
String _plain(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// The file name without its folder and extension.
String _baseName(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  var name = cut < 0 ? path : path.substring(cut + 1);
  final dot = name.lastIndexOf('.');
  if (dot > 0 && name.length - dot <= 5) name = name.substring(0, dot);
  return name;
}

bool _isPlaceholder(String value) =>
    MusicScanner.isUnknown(value) || isPlaceholderLyricsText(value);

/// Names that say « several people » or « nobody », never who sings.
const Set<String> _notAnArtist = {
  'various artists',
  'various',
  'va',
  'v a',
  'artistes divers',
  'divers',
  'compilation',
  'unknown artist',
};

/// A channel's suffix on an artist name: `RickAstleyVEVO`,
/// `Daft Punk - Topic`, `Stromae Official`.
final RegExp _channelSuffix = RegExp(
  r'(?:\s*-\s*topic|\s*vevo|\s+(?:official|officiel|youtube))$',
  caseSensitive: false,
);

/// The title to search for, from the title tag [tag] of the file at
/// [filePath] and [guess], what its name says.
///
/// - A placeholder, the bare file name, or `Artist - Title …` folded into
///   the tag: the guess's title, when it has one.
/// - A tag carrying a downloader's decoration (`(Lyrics)`, a video id,
///   underscores, a leading `01 `): the tag, cleaned — not the guess, which
///   may name something else entirely.
/// - Anything else is a real title, and stays.
String prefillTitle(
  String tag, {
  required String filePath,
  required FilenameGuess guess,
}) {
  final gTitle = guess.title.trim();
  final gArtist = _fold(guess.artist);
  final folded = _fold(tag);
  final foldedIn =
      gArtist.isNotEmpty &&
      gTitle.isNotEmpty &&
      folded != _fold(gTitle) &&
      folded.contains(gArtist) &&
      folded.contains(_fold(gTitle));
  if (_isPlaceholder(tag) ||
      folded == _fold(_baseName(filePath)) ||
      foldedIn) {
    return gTitle.isNotEmpty ? gTitle : tag;
  }
  final cleaned = FilenameParser.stripDecoration(tag);
  if (cleaned.isEmpty || _plain(cleaned) == _plain(tag)) return tag;
  return cleaned;
}

/// The artist to search for, from the artist tag [tag] and [guess].
///
/// A placeholder, « Various Artists » or a channel name (`…VEVO`,
/// `… - Topic`) gives way to the guess's artist; a channel with no guess to
/// replace it is at least stripped of its suffix (`RickAstleyVEVO` →
/// `Rick Astley`). A decorated tag is cleaned. A real name stays.
String prefillArtist(String tag, {required FilenameGuess guess}) {
  final gArtist = guess.artist.trim();
  final folded = _fold(tag);
  if (_isPlaceholder(tag) || _notAnArtist.contains(folded)) {
    return gArtist.isNotEmpty ? gArtist : tag;
  }
  final channel = _channelSuffix.firstMatch(tag.trim());
  if (channel != null) {
    if (gArtist.isNotEmpty) return gArtist;
    final bare = tag.trim().substring(0, channel.start).trim();
    if (bare.isEmpty) return tag;
    // `RickAstley` → `Rick Astley`: channel names run the words together.
    return bare.contains(' ')
        ? bare
        : bare.replaceAllMapped(
            RegExp(r'(?<=[a-z])(?=[A-Z])'),
            (_) => ' ',
          );
  }
  final cleaned = FilenameParser.stripDecoration(tag);
  if (cleaned.isEmpty || _plain(cleaned) == _plain(tag)) return tag;
  return cleaned;
}

/// Folders that say where a file was saved, not who made it.
const Set<String> _genericFolders = {
  'music',
  'musique',
  'musica',
  'musik',
  'audio',
  'audios',
  'download',
  'downloads',
  'telechargements',
  'telechargement',
  'documents',
  'mp3',
  'songs',
  'chansons',
  'media',
  'sdcard',
  'storage',
  'emulated',
  'whatsapp audio',
  'telegram audio',
  'recordings',
  'ringtones',
  'snaptube',
  'vidmate',
  'bluetooth',
  'shareit',
  'xender',
};

/// Context for the model that reads the file name: the folder it sits in
/// and the tags it carries, when either can tell it something. A bare
/// `01 - Track 1.mp3` says nothing; inside `Daft Punk - Discovery`, with a
/// title tag `One More Time`, it says everything.
///
/// Null when there is nothing worth sending — only placeholder tags and a
/// folder like `Download`.
String? aiFilenameHints({
  required String filePath,
  required String title,
  required String artist,
  required String album,
}) {
  final segments = filePath
      .split(RegExp(r'[/\\]'))
      .where((s) => s.trim().isNotEmpty)
      .toList();
  String? folder;
  if (segments.length >= 2) {
    final parent = segments[segments.length - 2].trim();
    final folded = foldForSearch(parent).trim();
    final generic =
        _genericFolders.contains(folded) ||
        // `0000-0000` (an SD card), `0`, `emulated/0`.
        RegExp(r'^[0-9a-f-]+$').hasMatch(folded);
    if (!generic) folder = parent;
  }
  final tags = <String>[
    if (!_isPlaceholder(title)) 'titre « ${title.trim()} »',
    if (!_isPlaceholder(artist)) 'artiste « ${artist.trim()} »',
    if (!_isPlaceholder(album)) 'album « ${album.trim()} »',
  ];
  if (folder == null && tags.isEmpty) return null;
  return [
    'Indices (souvent faux, le nom du fichier prime) :',
    if (folder != null) '- dossier : $folder',
    if (tags.isNotEmpty) '- tags actuels : ${tags.join(', ')}',
  ].join('\n');
}
