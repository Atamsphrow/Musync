/// Word timings that survive a restart.
///
/// A `SyncedLyrics` with words only exists in memory: the file formats the
/// app writes (SYLT/USLT/LRC) are line-level, so the words die at the
/// write. This store keeps them app-side, keyed by the file path and the
/// hash of the lyrics *text* — never in an enriched `.lrc` sidecar, which
/// other players would show raw.
///
/// One JSON file in the support dir (`lyrics_word_timings.json`), entries
/// cached in memory, atomic writes — the `LyricsMismatchStore` pattern.
///
/// Words are stored as offsets from their line's timestamp, not as absolute
/// track times: a nudge moves the line, and the words move with it for
/// free — no store update on any nudge or editor save. The key excludes
/// timestamps for the same reason: a retimed lyric keeps its words, while
/// editing one line's text changes the hash and the words stop attaching
/// (safe fallback: the line just renders without karaoke).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:path_provider/path_provider.dart';

/// One stored entry: the words of one file's lyrics.
///
/// [lines] maps a line index (into the synced lines, in order) to that
/// line's words, each word's `start` being its offset from the line's
/// timestamp — see the file doc.
typedef _WordEntry = ({String hash, Map<int, List<LyricWord>> lines});

/// FNV-1a 64-bit over the synced line texts, in order, as a hex string.
///
/// Text only — timestamps deliberately excluded, so retiming a lyric does
/// not invalidate its words. Separate from `lyricsContentHash` (which mixes
/// timestamps in, for change detection): the two answer different
/// questions, and sharing one would silently break the other.
String lyricsWordsHash(SyncedLyrics synced) {
  var h = 0xcbf29ce484222325;
  void mix(int value) {
    h = (h ^ value) * 0x100000001b3;
  }

  for (final line in synced.lines) {
    for (final unit in line.text.codeUnits) {
      mix(unit);
    }
    mix(0xFF); // Separator: "ab"+"c" must differ from "a"+"bc".
  }
  return h.toUnsigned(64).toRadixString(16);
}

class LyricsWordTimingsStore {
  /// Overridable so tests do not need `path_provider`.
  final Directory? root;

  LyricsWordTimingsStore({this.root});

  static const String _fileName = 'lyrics_word_timings.json';

  Map<String, _WordEntry>? _entries; // path -> entry
  bool _dirty = false;

  Future<File> _file() async {
    final dir = root ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<Map<String, _WordEntry>> _load() async {
    final cached = _entries;
    if (cached != null) return cached;
    final loaded = <String, _WordEntry>{};
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final parsed = _entryFromJson(entry.value);
            if (parsed != null) loaded['${entry.key}'] = parsed;
          }
        }
      }
    } catch (_) {
      // Illisible = aucune parole mot à mot : le comportement d'avant,
      // les lignes s'affichent sans karaoké.
    }
    return _entries = loaded;
  }

  static _WordEntry? _entryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final hash = raw['hash'];
    final rawLines = raw['lines'];
    if (hash is! String || rawLines is! Map) return null;
    final lines = <int, List<LyricWord>>{};
    for (final lineEntry in rawLines.entries) {
      final index = int.tryParse('${lineEntry.key}');
      final rawWords = lineEntry.value;
      if (index == null || rawWords is! List) continue;
      final words = <LyricWord>[];
      for (final rawWord in rawWords) {
        if (rawWord is! Map) continue;
        final offsetMs = rawWord['offsetMs'];
        final durationMs = rawWord['durationMs'];
        final text = rawWord['text'];
        if (offsetMs is! int || durationMs is! int || text is! String) {
          continue;
        }
        words.add(
          LyricWord(
            start: Duration(milliseconds: offsetMs),
            duration: Duration(milliseconds: durationMs),
            text: text,
            isBackground: rawWord['isBackground'] == true,
          ),
        );
      }
      if (words.isNotEmpty) lines[index] = words;
    }
    if (lines.isEmpty) return null;
    return (hash: hash, lines: lines);
  }

  /// Stores the words of [synced] for [filePath], as offsets from their
  /// line's timestamp. Replaces any entry the path already had.
  ///
  /// A no-op when [synced] carries no words: nothing to store, and — above
  /// all — nothing to delete. The sync editor and the nudge sheet save
  /// lyrics without words, and their saves must never kill karaoke.
  /// Persisted by [save].
  Future<void> saveWords(String filePath, SyncedLyrics synced) async {
    final lines = <int, List<LyricWord>>{};
    for (var i = 0; i < synced.lines.length; i++) {
      final line = synced.lines[i];
      if (line.words.isEmpty || line.timestamp == null) continue;
      lines[i] = [
        for (final word in line.words)
          LyricWord(
            start: word.start - line.timestamp!,
            duration: word.duration,
            text: word.text,
            isBackground: word.isBackground,
          ),
      ];
    }
    if (lines.isEmpty) return;
    (await _load())[filePath] = (
      hash: lyricsWordsHash(synced),
      lines: lines,
    );
    _dirty = true;
  }

  /// The [synced] lyrics with their stored words attached, when an entry
  /// matches [filePath] and the lyrics text.
  ///
  /// Returns [synced] itself — same instance — when nothing matches: no
  /// entry, a text edited since (hash mismatch), or a corrupt store. A
  /// miss is a fallback to line-only lyrics, never an error.
  Future<SyncedLyrics> attachWords(
    String filePath,
    SyncedLyrics synced,
  ) async {
    try {
      final entry = (await _load())[filePath];
      if (entry == null) return synced;
      if (entry.hash != lyricsWordsHash(synced)) return synced;
      var changed = false;
      final lines = <LyricLine>[];
      for (var i = 0; i < synced.lines.length; i++) {
        final line = synced.lines[i];
        final stored = entry.lines[i];
        if (stored == null || stored.isEmpty || line.timestamp == null) {
          lines.add(line);
          continue;
        }
        changed = true;
        lines.add(
          line.copyWith(
            words: [
              for (final word in stored)
                LyricWord(
                  start: line.timestamp! + word.start,
                  duration: word.duration,
                  text: word.text,
                  isBackground: word.isBackground,
                ),
            ],
          ),
        );
      }
      return changed ? SyncedLyrics(lines) : synced;
    } catch (_) {
      return synced;
    }
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
              'hash': e.value.hash,
              'lines': {
                for (final line in e.value.lines.entries)
                  '${line.key}': [
                    for (final word in line.value)
                      {
                        'offsetMs': word.start.inMilliseconds,
                        'durationMs': word.duration.inMilliseconds,
                        'text': word.text,
                        'isBackground': word.isBackground,
                      },
                  ],
              },
            },
        }),
      );
    } catch (_) {
      // Best effort : la prochaine écriture réessaiera.
      _dirty = true;
    }
  }
}

/// Le store partagé, injecté dans le dépôt et le lecteur.
///
/// Une seule instance pour toute l'app : le store met ses entrées en
/// cache en mémoire, donc une sauvegarde depuis l'écran de recherche
/// doit être visible du lecteur sans redémarrage.
final lyricsWordTimingsStoreProvider = Provider<LyricsWordTimingsStore>(
  (ref) => LyricsWordTimingsStore(),
);
