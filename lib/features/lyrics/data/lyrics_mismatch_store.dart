/// Morceaux marqués « non correspondant » : leurs paroles sont fausses
/// et l'utilisateur ne veut plus qu'on leur en télécharge.
///
/// Un fichier `lyrics_mismatches.json` (support dir) : une entrée par
/// chemin de fichier, avec l'identité (titre/artiste) au moment de la
/// marque — comme [SweepMemory], un morceau retaggé depuis n'est plus
/// le morceau marqué. Contrairement aux ratés du balayage, la marque
/// n'expire JAMAIS : une erreur reste une erreur jusqu'à ce que
/// l'utilisateur retire la marque, ou enregistre lui-même de vraies
/// paroles (voir [LyricsRepository.embedLyrics]).
///
/// Le balayage et [AiLyricsFinder] sautent les morceaux marqués : plus
/// aucun téléchargement automatique pour eux. Coller, chercher ou
/// éditer manuellement restent possibles.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:musync/core/utils/text_search.dart';
import 'package:path_provider/path_provider.dart';

/// Une marque : quand, et pour quelle identité (titre/artiste).
typedef _Mismatch = ({int at, String title, String artist});

class LyricsMismatchStore {
  /// Overridable so tests do not need `path_provider`.
  final Directory? root;

  LyricsMismatchStore({this.root});

  static const String _fileName = 'lyrics_mismatches.json';

  Map<String, _Mismatch>? _entries; // path -> marque
  bool _dirty = false;

  Future<File> _file() async {
    final dir = root ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<Map<String, _Mismatch>> _load() async {
    final cached = _entries;
    if (cached != null) return cached;
    final loaded = <String, _Mismatch>{};
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is Map) {
              final at = value['at'];
              if (at is int) {
                loaded['${entry.key}'] = (
                  at: at,
                  title: value['title'] is String
                      ? value['title'] as String
                      : '',
                  artist: value['artist'] is String
                      ? value['artist'] as String
                      : '',
                );
              }
            }
          }
        }
      }
    } catch (_) {
      // Mémoire illisible = aucun morceau marqué : le comportement
      // d'avant, les téléchargements reprennent.
    }
    return _entries = loaded;
  }

  /// Vrai quand [filePath] est marqué « non correspondant ».
  ///
  /// Faux quand le morceau a été retaggé depuis (titre/artiste
  /// différents de ceux de la marque) : la marque ne porte plus sur
  /// ce morceau. Sans identité mémorisée, la marque s'applique.
  /// La marque n'expire jamais.
  Future<bool> isMismatched(
    String filePath, {
    String? title,
    String? artist,
  }) async {
    final mark = (await _load())[filePath];
    if (mark == null) return false;
    if (mark.title.isNotEmpty &&
        title != null &&
        foldForSearch(mark.title) != foldForSearch(title)) {
      return false;
    }
    if (mark.artist.isNotEmpty &&
        artist != null &&
        foldForSearch(mark.artist) != foldForSearch(artist)) {
      return false;
    }
    return true;
  }

  /// Marque [filePath] « non correspondant », avec l'identité du
  /// morceau au moment du marquage. Persistée par [save].
  Future<void> markMismatched(
    String filePath, {
    String title = '',
    String artist = '',
  }) async {
    (await _load())[filePath] = (
      at: DateTime.now().millisecondsSinceEpoch,
      title: title,
      artist: artist,
    );
    _dirty = true;
  }

  /// Retire la marque de [filePath] (retrait manuel, ou vraies paroles
  /// enregistrées). Persistée par [save].
  Future<void> unmark(String filePath) async {
    if ((await _load()).remove(filePath) != null) _dirty = true;
  }

  /// Écrit le store (atomiquement) s'il a changé.
  Future<void> save() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      final entries = await _load();
      await AtomicFile.writeString(
        await _file(),
        jsonEncode({
          for (final e in entries.entries)
            e.key: {
              'at': e.value.at,
              'title': e.value.title,
              'artist': e.value.artist,
            },
        }),
      );
    } catch (_) {
      // Best effort : la prochaine écriture réessaiera.
      _dirty = true;
    }
  }
}

/// Le store partagé, injecté dans le finder, le dépôt et le balayage.
///
/// Une seule instance pour toute l'app : le store met ses entrées en
/// cache en mémoire, donc un marquage depuis l'écran lecteur doit
/// être visible du balayage sans redémarrage — ce qu'une instance par
/// lecteur (le patron de SweepMemory, mono-propriétaire) ne donnerait
/// pas.
final lyricsMismatchStoreProvider = Provider<LyricsMismatchStore>(
  (ref) => LyricsMismatchStore(),
);
