import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/id3_reader.dart';
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

  /// The plain-text side, written to USLT alongside SYLT so the lyrics stay
  /// readable in players that ignore synchronised frames.
  UnsyncedLyrics get asUnsyncedLyrics =>
      UnsyncedLyrics(lines.map((l) => l.text).join('\n'));
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

  static List<LyricLine> _linesFromText(String text) => [
        for (final line in text.split('\n'))
          LyricLine(timestamp: Duration.zero, text: line.trim()),
      ];

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
      state.lines[index]
          .copyWith(timestamp: timestamp.isNegative ? Duration.zero : timestamp),
    );
  }

  /// Nudges one line, leaving the rest alone.
  void nudgeLine(int index, Duration delta) {
    if (index < 0 || index >= state.lines.length) return;
    updateTimestamp(index, state.lines[index].timestamp + delta);
  }

  /// Shifts every line at once. Tracks the running total so the readout says
  /// what has actually been applied instead of a hardcoded zero.
  void offsetAll(Duration delta) {
    if (state.lines.isEmpty) return;
    final shifted = [
      for (final line in state.lines)
        line.copyWith(
          timestamp: (line.timestamp + delta).isNegative
              ? Duration.zero
              : line.timestamp + delta,
        ),
    ];
    state = state.copyWith(
      lines: shifted,
      globalOffset: state.globalOffset + delta,
      hasChanges: true,
    );
  }

  /// Clears every timestamp without touching the text, so a badly timed file
  /// can be redone from scratch.
  void resetTimings() {
    state = state.copyWith(
      lines: [
        for (final line in state.lines) line.copyWith(timestamp: Duration.zero)
      ],
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
  void replaceAllText(String text) {
    final incoming = text.split('\n').map((l) => l.trim()).toList();
    final lines = <LyricLine>[
      for (var i = 0; i < incoming.length; i++)
        LyricLine(
          timestamp: i < state.lines.length
              ? state.lines[i].timestamp
              : Duration.zero,
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
          // right place rather than jumping to the top of the song.
          timestamp: index >= 0 && index < state.lines.length
              ? state.lines[index].timestamp
              : Duration.zero,
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
