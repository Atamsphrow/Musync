/// Which lyrics providers answer, and which are set aside.
///
/// A source that fails three times in a row (network, timeout, a 5xx —
/// whatever its provider throws as a [LyricsSourceException]) is set aside
/// for ten minutes: it is not asked, so a provider that is down costs no
/// waiting. And "no lyrics for this song" from a source is kept for five
/// minutes per query and source, so reopening a song does not ask again.
/// A failure is never kept as "no lyrics": an empty answer is an answer,
/// and only answers count towards the memo.
///
/// The idea is myspoti's `LyricsHealth`, re-implemented from the idea
/// (GPL-3.0 — no Kotlin was copied): the streaks, the cooldown, the
/// missing memo and the constants are the mechanism itself, written here
/// in Dart structures of our own.
///
/// In memory only: a restart clears the cooldowns and the memo, and the
/// source gets one fresh chance. A ten-minute cooldown does not need to
/// outlive the app — the next failure puts it straight back aside.
library;

import 'package:musync/core/utils/text_search.dart';

/// The key of a "no lyrics" memo: the folded query, so "Café" and "cafe"
/// memoise together, and the source that said so.
String lyricsHealthTrackKey(String title, String artist) =>
    '${foldForSearch(title)}|${foldForSearch(artist)}';

class LyricsSourceHealth {
  /// Failures in a row before a source is set aside.
  static const int failuresInARow = 3;

  /// How long a source that failed three times in a row is set aside.
  static const Duration setAsideFor = Duration(minutes: 10);

  /// How long "no lyrics for this query" is remembered, per source.
  static const Duration missingFor = Duration(minutes: 5);

  /// Upper bound on remembered "no lyrics" answers. Expired entries are
  /// evicted first, so the cap is only reached by genuinely recent ones.
  static const int maxMissing = 500;

  final DateTime Function() _now;

  LyricsSourceHealth({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Map<String, int> _streaks = {};
  final Map<String, DateTime> _setAsideUntil = {};
  final Map<String, DateTime> _missing = {};

  /// How long [source] is still set aside, or null when it may be asked.
  Duration? setAsideRemaining(String source) {
    final until = _setAsideUntil[source];
    if (until == null) return null;
    final remaining = until.difference(_now());
    if (remaining <= Duration.zero) {
      _setAsideUntil.remove(source);
      return null;
    }
    return remaining;
  }

  /// True when [source] is set aside right now.
  bool isSetAside(String source) => setAsideRemaining(source) != null;

  /// [source] answered (found lyrics or not): its failures in a row end.
  /// A set-aside is lifted too: the only way a set-aside source answers
  /// is a manual bypass, and an answer proves it is back.
  void answered(String source) {
    _streaks.remove(source);
    _setAsideUntil.remove(source);
  }

  /// A request to [source] failed. Three in a row sets it aside.
  void failed(String source) {
    final n = (_streaks[source] ?? 0) + 1;
    if (n >= failuresInARow) {
      _streaks.remove(source);
      _setAsideUntil[source] = _now().add(setAsideFor);
    } else {
      _streaks[source] = n;
    }
  }

  /// True when [source] already said "no lyrics" for this query within
  /// the last five minutes.
  bool isMissing(String trackKey, String source) {
    final at = _missing['$source|$trackKey'];
    if (at == null) return false;
    if (_now().difference(at) < missingFor) return true;
    _missing.remove('$source|$trackKey');
    return false;
  }

  /// Remember that [source] has no lyrics for this query.
  void noteMissing(String trackKey, String source) {
    if (_missing.length >= maxMissing) {
      final now = _now();
      _missing.removeWhere((_, at) => now.difference(at) >= missingFor);
    }
    _missing['$source|$trackKey'] = _now();
  }

  /// The query is asked again on purpose (the user pressed Rechercher):
  /// its "no lyrics" answers are dropped, so the sources are asked again.
  /// The set-aside cooldowns are untouched — a source that is down stays
  /// down until its time is up or a manual bypass succeeds.
  void forgetTrack(String trackKey) {
    _missing.removeWhere((key, _) => key.endsWith('|$trackKey'));
  }
}
