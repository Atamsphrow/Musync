import 'dart:convert';
import 'dart:io';

import 'package:musync/core/utils/atomic_file.dart';
import 'package:musync/core/utils/text_search.dart';
import 'package:path_provider/path_provider.dart';

/// Un raté confirmé : quand, et pour quelle identité (titre/artiste).
///
/// L'identité est la clé de l'invalidation sur retag : un morceau
/// retaggé depuis la dernière tentative n'est plus le morceau dont on
/// a confirmé l'absence. Les anciennes entrées (simple entier) n'ont
/// pas d'identité et gardent l'ancien comportement.
typedef _Miss = ({int at, String title, String artist});

/// Remembers, across launches, the tracks the background sweep
/// searched and CONFIRMEDLY found nothing for, so the next launch
/// (and the daily headless worker) skips them for a while instead of
/// re-querying the network — and the AI fallback — for every one of
/// them on every single launch.
///
/// Only confirmed misses belong here: a network failure, a missing
/// write permission or a failed write must never be remembered, or a
/// passing outage would silence a track for the whole validity
/// window. [BackgroundLyricsService] is the only writer and marks a
/// miss only at the exact point where searches succeeded and no
/// match came back.
class SweepMemory {
  /// Overridable so tests do not need `path_provider`.
  final Directory? root;

  SweepMemory({this.root});

  static const String _fileName = 'lyrics_sweep_misses.json';

  /// How long a confirmed miss stays believed. Lyrics databases grow;
  /// a fortnight is long enough to kill the launch-after-launch
  /// re-querying without writing a track off for good.
  static const Duration validity = Duration(days: 14);

  Map<String, _Miss>? _misses; // path -> last confirmed miss
  bool _dirty = false;

  Future<File> _file() async {
    final dir = root ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<Map<String, _Miss>> _load() async {
    final cached = _misses;
    if (cached != null) return cached;
    final loaded = <String, _Miss>{};
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is int) {
              // Ancienne forme (simple horodatage) : sans identité.
              loaded['${entry.key}'] = (
                at: value,
                title: '',
                artist: '',
              );
            } else if (value is Map) {
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
      // Unreadable memory = search again, which is what happened before.
    }
    return _misses = loaded;
  }

  /// Whether [filePath] was confirmed missed within [validity].
  ///
  /// Faux quand le morceau a été retaggé depuis (titre/artiste
  /// différents de ceux de la tentative) : la clé n'est plus le chemin
  /// seul. Sans identité mémorisée (ancienne entrée), l'ancien
  /// comportement s'applique.
  Future<bool> recentlyMissed(
    String filePath, {
    String? title,
    String? artist,
  }) async {
    final miss = (await _load())[filePath];
    if (miss == null) return false;
    if (miss.title.isNotEmpty &&
        title != null &&
        foldForSearch(miss.title) != foldForSearch(title)) {
      return false;
    }
    if (miss.artist.isNotEmpty &&
        artist != null &&
        foldForSearch(miss.artist) != foldForSearch(artist)) {
      return false;
    }
    final age = DateTime.now().millisecondsSinceEpoch - miss.at;
    return age >= 0 && age < validity.inMilliseconds;
  }

  /// Records a confirmed miss for [filePath], avec l'identité du morceau
  /// au moment de la tentative. Persisted by [save].
  ///
  /// À n'appeler que sur une absence confirmée sur une bonne requête :
  /// un raté réseau ou une requête à placeholders ne doit jamais taire
  /// un morceau 14 jours — c'est l'appelant qui le garantit.
  Future<void> markMissed(
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

  /// Writes the memory out (atomically) if anything changed.
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
      // Best effort: the cost of a failed save is searching again
      // next time — the pre-memory behaviour.
    }
  }
}
