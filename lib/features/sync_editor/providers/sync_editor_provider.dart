import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/library/data/models/song.dart';

/// Simple = the text alone (USLT). Synchronisé = the text with timestamps
/// (SYLT). The toggle mirrors Musicolet's.
enum SyncMode { simple, synced }

@immutable
class SyncEditorState {
  /// Lines in **reading order**, which is not necessarily timestamp order
  /// while the user is part-way through timing a song. Sorting only happens
  /// when the result is converted to [SyncedLyrics] on save.
  final List<LyricLine> lines;

  final SyncMode mode;

  /// The line the stamp button will time next. This is the whole editor: the
  /// user plays the track and taps once per line as it comes.
  final int cursor;

  /// Sum of the global nudges applied this session, for the offset readout.
  /// Reset by a save — it describes the pending change, not the file.
  final Duration globalOffset;

  final bool isLoading;
  final bool isSaving;
  final bool hasChanges;

  const SyncEditorState({
    this.lines = const [],
    this.mode = SyncMode.synced,
    this.cursor = 0,
    this.globalOffset = Duration.zero,
    this.isLoading = true,
    this.isSaving = false,
    this.hasChanges = false,
  });

  SyncEditorState copyWith({
    List<LyricLine>? lines,
    SyncMode? mode,
    int? cursor,
    Duration? globalOffset,
    bool? isLoading,
    bool? isSaving,
    bool? hasChanges,
  }) {
    return SyncEditorState(
      lines: lines ?? this.lines,
      mode: mode ?? this.mode,
      cursor: cursor ?? this.cursor,
      globalOffset: globalOffset ?? this.globalOffset,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      hasChanges: hasChanges ?? this.hasChanges,
    );
  }

  bool get isEmpty => lines.isEmpty;

  /// Timestamp-ordered view, for playback highlighting and for saving.
  SyncedLyrics get asSyncedLyrics => SyncedLyrics(lines);

  /// The plain-text side, written to USLT alongside SYLT.
  ///
  /// LRC-formatted as soon as anything is timed, because that is where players
  /// which ignore SYLT go looking for the timings — Musicolet among them. See
  /// `Id3Writer.writeLyrics`.
  ///
  /// Lines the user deliberately left untimed are emitted bare. They keep their
  /// place among the words without claiming a time they don't have, which is
  /// the whole point of being able to strip one: `[Refrain]` belongs in the
  /// lyric, but must never be sung at a particular second.
  UnsyncedLyrics get asUnsyncedLyrics {
    if (!lines.any((line) => line.isTimed)) {
      return UnsyncedLyrics(lines.map((l) => l.text).join('\n'));
    }

    return UnsyncedLyrics(
      [
        for (final line in lines)
          if (line.isTimed)
            '[${LrcParser.formatTimestamp(line.timestamp!)}]${line.text}'
          else
            line.text,
      ].join('\n'),
    );
  }
}

class SyncEditorNotifier extends StateNotifier<SyncEditorState> {
  final Song song;

  SyncEditorNotifier(this.song) : super(const SyncEditorState()) {
    _load();
  }

  /// Reads what is already in the file. The file is the source of truth: the
  /// editor is always opened on a track whose lyrics were just embedded or are
  /// already there.
  Future<void> _load() async {
    final pair = await Id3Reader.readLyrics(song.filePath);
    if (!mounted) return;

    final synced = pair.synced;
    if (synced != null && synced.isNotEmpty) {
      state = state.copyWith(lines: synced.lines, isLoading: false);
      return;
    }

    // Only plain lyrics: seed every line at zero so the user can time them.
    // That is exactly the "untimed → timed" path the editor exists for.
    final plain = pair.unsynced;
    state = state.copyWith(
      lines: plain == null ? const [] : _linesFromText(plain.text),
      mode: plain == null ? SyncMode.synced : SyncMode.simple,
      isLoading: false,
    );
  }

  /// Seeds the editor from plain text, honouring LRC prefixes if they are there.
  ///
  /// Pasting an LRC file into the simple editor is an ordinary thing to do, and
  /// keeping `[00:12.30]` as part of the lyric is exactly the failure T11
  /// describes: the brackets showed up on screen as words while the timestamp
  /// field stayed empty, so nothing could scroll or highlight.
  ///
  /// Text with no timings yields untimed lines rather than lines pinned at
  /// zero. They are two different claims — "not timed yet" and "timed, at the
  /// very start" — and only the first one is true here.
  static List<LyricLine> _linesFromText(String text) {
    final parsed = LrcParser.parse(text);
    if (parsed.isNotEmpty) return parsed.lines;

    return [
      for (final line in text.split('\n'))
        LyricLine(timestamp: null, text: line.trim()),
    ];
  }

  // ── Timing ──

  /// The central gesture: stamp the cursor line at [position] and step on.
  ///
  /// Returns the line that was stamped, or null when the cursor has run off
  /// the end — the caller uses that to stop scrolling.
  int? stampCursorAt(Duration position) {
    final index = state.cursor;
    if (index < 0 || index >= state.lines.length) return null;

    _replaceLine(index, state.lines[index].copyWith(timestamp: position));
    state = state.copyWith(cursor: index + 1);
    return index;
  }

  void setCursor(int index) {
    state = state.copyWith(cursor: index.clamp(0, state.lines.length));
  }

  void updateTimestamp(int index, Duration timestamp) {
    if (index < 0 || index >= state.lines.length) return;
    _replaceLine(
      index,
      state.lines[index].copyWith(
        timestamp: timestamp.isNegative ? Duration.zero : timestamp,
      ),
    );
  }

  /// Puts one line back to un-timed and parks the cursor on it, so the next tap
  /// of *Caler* re-times exactly that line.
  ///
  /// This is the "retry this one" the spec asks for. Without it, a single
  /// mis-tapped line meant either living with it or redoing everything after.
  /// Same reason as [resetTimings]: this parked the line at `00:00.00` instead
  /// of clearing it, so a line the user had just said was wrong was left
  /// claiming to be sung at the start of the track.
  void resetLineTiming(int index) {
    if (index < 0 || index >= state.lines.length) return;
    clearTimestamp(index);
    state = state.copyWith(cursor: index);
  }

  /// Strips a line's time while keeping its words.
  ///
  /// For structural markers — `[Refrain]`, `[Pont]` — which belong to the lyric
  /// as text but must never be flashed up as though they were sung. The line
  /// stays in the plain text written to USLT and drops out of SYLT entirely.
  void clearTimestamp(int index) {
    if (index < 0 || index >= state.lines.length) return;
    _replaceLine(index, state.lines[index].withoutTimestamp());
  }

  /// Nudges one line, leaving the rest alone.
  void nudgeLine(int index, Duration delta) {
    if (index < 0 || index >= state.lines.length) return;
    final line = state.lines[index];
    if (!line.isTimed) return;
    updateTimestamp(index, line.timestamp! + delta);
  }

  /// Shifts every line at once. Tracks the running total so the readout says
  /// what has actually been applied instead of a hardcoded zero.
  void offsetAll(Duration delta) {
    if (state.lines.isEmpty) return;
    state = state.copyWith(
      lines: [for (final line in state.lines) _shifted(line, delta)],
      globalOffset: state.globalOffset + delta,
      hasChanges: true,
    );
  }

  /// Shifts [index] and everything after it, leaving earlier lines alone.
  ///
  /// This is what the nudge buttons in the *Décaler* section call. Nudging the
  /// first line therefore moves the whole song, which is the common case — a
  /// lyric sourced online is usually right relative to itself and simply starts
  /// early or late. Nudging further down fixes a track that drifts from a
  /// point, without disturbing the part already timed correctly.
  void nudgeFrom(int index, Duration delta) {
    if (index < 0 || index >= state.lines.length) return;

    final lines = <LyricLine>[
      for (var i = 0; i < state.lines.length; i++)
        if (i < index) state.lines[i] else _shifted(state.lines[i], delta),
    ];

    state = state.copyWith(
      lines: lines,
      // Only a shift of the whole song is a "global offset" as far as the
      // readout is concerned; a partial one would make the number a lie.
      globalOffset: index == 0
          ? state.globalOffset + delta
          : state.globalOffset,
      hasChanges: true,
    );
  }

  /// Re-times the whole song from a single line heard in place.
  ///
  /// The gesture the sync editor is really for, when a lyric is already timed
  /// but sits early or late as a block — which is what an LRC pulled off the
  /// internet almost always is. The user plays the track, waits for the moment
  /// line [index] should land, and taps once. The difference between where it
  /// *is* and where it was *heard* becomes a shift applied to every line, so
  /// the spacing already correct between lines survives untouched.
  ///
  /// Distinct from the nudge buttons: there the delta is dialled in by hand,
  /// here it is measured off the playhead.
  ///
  /// Returns the shift applied, or null when [index] had no time to measure
  /// against — in which case the line is simply stamped and the rest left be,
  /// since there is no drift to infer from a line that was never placed.
  Duration? alignAllFrom(int index, Duration heardAt) {
    if (index < 0 || index >= state.lines.length) return null;

    final current = state.lines[index].timestamp;
    if (current == null) {
      updateTimestamp(index, heardAt);
      return null;
    }

    final delta = heardAt - current;
    if (delta != Duration.zero) offsetAll(delta);
    return delta;
  }

  /// Undoes the accumulated global offset, putting the timings back where they
  /// were when the editor opened — without touching per-line nudges, which are
  /// not part of the running total.
  void resetOffset() {
    if (state.globalOffset == Duration.zero) return;
    final delta = -state.globalOffset;
    state = state.copyWith(
      lines: [for (final line in state.lines) _shifted(line, delta)],
      globalOffset: Duration.zero,
      hasChanges: true,
    );
  }

  /// Moves a line in time, floored at zero.
  ///
  /// An untimed line comes back untouched. There is no time to shift, and
  /// handing it one would quietly undo the user's decision to strip it — which
  /// is precisely what a `[Refrain]` marker is doing by having none.
  static LyricLine _shifted(LyricLine line, Duration delta) => line.isTimed
      ? line.copyWith(timestamp: _floorAtZero(line.timestamp! + delta))
      : line;

  static Duration _floorAtZero(Duration d) => d.isNegative ? Duration.zero : d;

  /// Clears every timestamp without touching the text, so a badly timed file
  /// can be redone from scratch.
  ///
  /// Un-timed, not timed-at-zero. This wrote `Duration.zero` and so left every
  /// line reading `00:00.00` — which is a claim, and a false one: it says the
  /// whole song is sung at the very first instant. Saving that would have
  /// produced a SYLT with every line stacked on zero. `--:--.--` is what "no
  /// timing" looks like, and an untimed line drops out of SYLT on the way to the
  /// file while keeping its words in the plain frame.
  void resetTimings() {
    state = state.copyWith(
      lines: [for (final line in state.lines) line.withoutTimestamp()],
      cursor: 0,
      globalOffset: Duration.zero,
      hasChanges: true,
    );
  }

  // ── Text ──

  void updateLineText(int index, String text) {
    if (index < 0 || index >= state.lines.length) return;
    _replaceLine(index, state.lines[index].copyWith(text: text));
  }

  /// Replaces the whole lyric from pasted text (plan §3.3).
  ///
  /// Timestamps already set are kept line by line where the count allows, so
  /// fixing a typo in the third verse doesn't throw away the timing of the
  /// first two.
  ///
  /// Lines beyond what was there before arrive **untimed**. They used to arrive
  /// at `Duration.zero`, which reads as `00:00.00` and says the line is sung at
  /// the very first instant — a claim, and a false one, that would have gone
  /// straight into SYLT. Same correction as `resetTimings`.
  void replaceAllText(String text) {
    final incoming = text.split('\n').map((l) => l.trim()).toList();
    final lines = <LyricLine>[
      for (var i = 0; i < incoming.length; i++)
        LyricLine(
          timestamp: i < state.lines.length ? state.lines[i].timestamp : null,
          text: incoming[i],
        ),
    ];
    state = state.copyWith(
      lines: lines,
      cursor: state.cursor.clamp(0, lines.length),
      hasChanges: true,
    );
  }

  void insertLineAfter(int index) {
    final at = (index + 1).clamp(0, state.lines.length);
    final lines = List<LyricLine>.from(state.lines)
      ..insert(
        at,
        LyricLine(
          // A new line inherits the timestamp above it, so it lands in the
          // right place rather than jumping to the top of the song. With no line
          // above it there is nothing to inherit, and it stays untimed rather
          // than claiming the first instant.
          timestamp: index >= 0 && index < state.lines.length
              ? state.lines[index].timestamp
              : null,
          text: '',
        ),
      );
    state = state.copyWith(lines: lines, hasChanges: true);
  }

  void removeLine(int index) {
    if (index < 0 || index >= state.lines.length) return;
    final lines = List<LyricLine>.from(state.lines)..removeAt(index);
    state = state.copyWith(
      lines: lines,
      cursor: state.cursor.clamp(0, lines.length),
      hasChanges: true,
    );
  }

  void setMode(SyncMode mode) => state = state.copyWith(mode: mode);

  void setSaving(bool saving) => state = state.copyWith(isSaving: saving);

  /// Called once the write has landed: the pending-change markers describe the
  /// gap between the editor and the file, and there is no longer one.
  void markSaved() => state = state.copyWith(
    hasChanges: false,
    isSaving: false,
    globalOffset: Duration.zero,
  );

  void _replaceLine(int index, LyricLine line) {
    final lines = List<LyricLine>.from(state.lines)..[index] = line;
    state = state.copyWith(lines: lines, hasChanges: true);
  }
}

/// Keyed by [Song] — which has value equality, so the notifier survives a
/// rebuild instead of being replaced (and leaked) on every frame.
final syncEditorProvider = StateNotifierProvider.autoDispose
    .family<SyncEditorNotifier, SyncEditorState, Song>(
      (ref, song) => SyncEditorNotifier(song),
    );
