import 'package:flutter/foundation.dart';
import 'package:musync/core/id3/lrc_parser.dart';

/// One line of a song, timed or not.
///
/// A null [timestamp] means the line deliberately has no time of its own.
/// Structural markers — `[Refrain]`, `[Couplet 2]` — are why this is nullable:
/// they belong to the lyric as text, but a synchronised player must never flash
/// one up mid-song. Such a line stays in the plain text (USLT) and is left out
/// of SYLT entirely.
@immutable
class LyricLine implements Comparable<LyricLine> {
  final Duration? timestamp;
  final String text;

  const LyricLine({required this.timestamp, required this.text});

  bool get isTimed => timestamp != null;

  LyricLine copyWith({Duration? timestamp, String? text}) => LyricLine(
    timestamp: timestamp ?? this.timestamp,
    text: text ?? this.text,
  );

  /// Drops the time and keeps the words.
  ///
  /// A separate method because `copyWith(timestamp: null)` means "leave it
  /// alone" by the convention every other copyWith in this codebase follows;
  /// overloading it to mean "clear it" would make the two indistinguishable.
  LyricLine withoutTimestamp() => LyricLine(timestamp: null, text: text);

  /// Untimed lines sort last. They never reach SYLT, so this only decides where
  /// they sit in a list that still holds them — the editor's, in practice.
  @override
  int compareTo(LyricLine other) => switch ((timestamp, other.timestamp)) {
    (null, null) => 0,
    (null, _) => 1,
    (_, null) => -1,
    (final a?, final b?) => a.compareTo(b),
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LyricLine &&
        other.timestamp == timestamp &&
        other.text == text;
  }

  @override
  int get hashCode => Object.hash(timestamp, text);

  @override
  String toString() => timestamp == null
      ? 'LyricLine(sans heure, "$text")'
      : 'LyricLine(${timestamp!.inMilliseconds}ms, "$text")';
}

/// Timed lyrics, held in ascending timestamp order.
///
/// SYLT requires ascending timestamps, so sorting happens here rather than
/// being left to callers. The sort is *stable*: lines sharing a timestamp keep
/// the order they were written in, which is what preserves the reading order of
/// a verse the user has not finished timing yet. `List.sort` gives no such
/// guarantee, hence the explicit index tie-break.
///
/// **Untimed lines are dropped on the way in.** This class is what eventually
/// becomes a SYLT frame, and a line with no timestamp has nothing to contribute
/// to one. Nothing is lost by it: the editor keeps its own list of every line,
/// and the plain-text side written to USLT is built from that, so a `[Refrain]`
/// marker survives in the words while staying out of the timings. Every member
/// below can therefore treat `timestamp` as non-null.
@immutable
class SyncedLyrics {
  final List<LyricLine> lines;

  SyncedLyrics(List<LyricLine> lines)
    : lines = List.unmodifiable(
        _sorted([
          for (final line in lines)
            if (line.isTimed) line,
        ]),
      );

  static List<LyricLine> _sorted(List<LyricLine> lines) {
    final indexed = List<({int index, LyricLine line})>.generate(
      lines.length,
      (i) => (index: i, line: lines[i]),
      growable: false,
    );
    indexed.sort((a, b) {
      final byTime = a.line.timestamp!.compareTo(b.line.timestamp!);
      return byTime != 0 ? byTime : a.index.compareTo(b.index);
    });
    return [for (final entry in indexed) entry.line];
  }

  factory SyncedLyrics.fromLrc(String lrc) => LrcParser.parse(lrc);

  factory SyncedLyrics.empty() => SyncedLyrics(const []);

  /// Index of the line active at [position] — the last one already started —
  /// or null before the first line.
  int? getLineAt(Duration position) {
    if (lines.isEmpty) return null;

    int low = 0;
    int high = lines.length - 1;
    int? result;

    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (lines[mid].timestamp! <= position) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  String toLrc() => LrcParser.generate(this);

  /// Shifts every line by [offset], floored at zero.
  SyncedLyrics offsetAll(Duration offset) {
    return SyncedLyrics([
      for (final line in lines)
        line.copyWith(timestamp: _floorAtZero(line.timestamp! + offset)),
    ]);
  }

  SyncedLyrics offsetLine(int index, Duration offset) {
    if (index < 0 || index >= lines.length) return this;

    final updated = List<LyricLine>.from(lines);
    updated[index] = updated[index].copyWith(
      timestamp: _floorAtZero(updated[index].timestamp! + offset),
    );
    return SyncedLyrics(updated);
  }

  static Duration _floorAtZero(Duration d) => d.isNegative ? Duration.zero : d;

  /// Flattens to plain text, for writing the USLT frame alongside SYLT.
  String toPlainText() => lines.map((l) => l.text).join('\n');

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
  int get length => lines.length;

  /// Value equality, on purpose: these are used as Riverpod family keys and as
  /// comparison targets in tests. Identity semantics would hand out a fresh
  /// notifier on every rebuild and leak one provider per frame.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SyncedLyrics && listEquals(other.lines, lines);
  }

  @override
  int get hashCode => Object.hashAll(lines);

  @override
  String toString() => 'SyncedLyrics(${lines.length} lignes)';
}

/// Plain, untimed lyrics — the USLT frame.
@immutable
class UnsyncedLyrics {
  final String text;

  const UnsyncedLyrics(this.text);

  bool get isEmpty => text.trim().isEmpty;
  bool get isNotEmpty => !isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is UnsyncedLyrics && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'UnsyncedLyrics(${text.length} caractères)';
}
