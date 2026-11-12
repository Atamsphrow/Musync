import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/features/lyrics/data/genius_meaning.dart';
import 'package:musync/features/lyrics/ui/embed_lyrics_action.dart';
import 'package:musync/features/lyrics/ui/meaning_sheet.dart';
import 'package:musync/features/player/providers/player_provider.dart';

/// The text shared for a line: the line quoted, with its song.
String shareQuote({
  required String line,
  required String artist,
  required String title,
}) => '« ${line.trim()} » — $artist – $title';

/// Opens the quick ±100 ms timing sheet for one synced line.
///
/// Taps apply instantly in memory — no file write between taps, so a burst
/// of five or six stays fluid. The accumulated nudge is written once, when
/// the sheet closes: one backup, one history entry, one snackbar with the
/// total.
///
/// Writing per tap used to stack a full backup + invalidate cascade on every
/// tap, and rapid taps crashed the app (`Concurrent modification during
/// iteration` inside Riverpod). One write per session removes the race at
/// the root.
Future<void> showNudgeLineSheet(
  BuildContext context,
  WidgetRef ref, {
  required String filePath,
  required SyncedLyrics synced,
  required UnsyncedLyrics? unsynced,
  required int index,
  required String title,
  required String artist,
  GeniusMeaningService? meaningService,
}) async {
  final session = _NudgeSession(initialSynced: synced);
  await showModalBottomSheet<void>(
    context: context,
    builder: (_) => _NudgeLineSheet(
      filePath: filePath,
      unsynced: unsynced,
      index: index,
      session: session,
      title: title,
      artist: artist,
      meaningService: meaningService,
    ),
  );
  if (!session.dirty) return;
  if (!context.mounted) return;
  await embedLyrics(
    context,
    ref,
    filePath: filePath,
    synced: session.synced,
    unsynced: unsynced,
    // This sheet owns the whole synced state for the session, like the sync
    // editor does — a plain-text write must not wipe the timings.
    onPlainOverSynced: PlainOverSynced.replace,
    successMessage: _successMessage(session),
  );
}

/// What the write is announced as, once it lands.
///
/// A nudge session says how far the line moved; a deletion says the line is
/// gone. Both can happen in one session, so the message is built from parts
/// instead of assuming one shape.
String _successMessage(_NudgeSession session) {
  final parts = <String>[];
  if (session.removedCount > 0) {
    parts.add(
      session.removedCount == 1
          ? 'Ligne vide supprimée.'
          : '${session.removedCount} lignes vides supprimées.',
    );
  }
  if (session.totalDelta != Duration.zero) {
    final totalMs = session.totalDelta.inMilliseconds.abs();
    parts.add(
      '« ${session.lineText} » ${session.totalDelta.isNegative ? '−' : '+'}$totalMs ms.',
    );
  }
  return parts.join(' ');
}

/// The taps of one sheet session, accumulated in memory.
///
/// A plain mutable holder, shared with the sheet's state: however the sheet
/// closes (drag, tap outside, back), the caller reads [dirty] afterwards.
/// No PopScope dance needed.
class _NudgeSession {
  _NudgeSession({required SyncedLyrics initialSynced})
      : _synced = initialSynced;

  SyncedLyrics _synced;
  SyncedLyrics get synced => _synced;

  /// Sum of the deltas actually applied (a −100 ms tap on a 50 ms timestamp
  /// only moves 50 ms). Zero means nothing changed: no write, no history.
  Duration totalDelta = Duration.zero;

  /// Lines removed this session. A removal alone makes the session dirty:
  /// without it a delete with no nudge would never be written.
  int removedCount = 0;

  /// The line's text at the last tap, for the summary snackbar.
  String lineText = '';

  bool get dirty => totalDelta != Duration.zero || removedCount > 0;

  /// Applies one step in memory and returns the updated state, or null when
  /// the tap changes nothing.
  ({SyncedLyrics synced, int index})? nudge(
    int index,
    Duration delta,
  ) {
    if (index < 0 || index >= _synced.lines.length) return null;
    final line = _synced.lines[index];
    final timestamp = line.timestamp;
    // Untimed lines never reach SyncedLyrics, but never trust it blindly.
    if (timestamp == null) return null;
    // Floored at zero, like SyncedLyrics.offsetAll.
    final next = timestamp + delta < Duration.zero
        ? Duration.zero
        : timestamp + delta;
    if (next == timestamp) return null;
    final nudgedLine = line.copyWith(timestamp: next);
    // The constructor re-sorts, so re-locate the line by identity instead of
    // trusting the old index.
    final nudged = SyncedLyrics([
      for (var i = 0; i < _synced.lines.length; i++)
        i == index ? nudgedLine : _synced.lines[i],
    ]);
    totalDelta += next - timestamp;
    lineText = nudgedLine.text.trim();
    _synced = nudged;
    return (synced: nudged, index: nudged.lines.indexOf(nudgedLine));
  }

  /// Removes the line at [index] from the session state.
  ///
  /// Only ever called for an empty line — the sheet shows the button for
  /// those alone. Returns false when there is nothing to remove.
  bool removeLine(int index) {
    if (index < 0 || index >= _synced.lines.length) return false;
    final lines = List<LyricLine>.from(_synced.lines)..removeAt(index);
    _synced = SyncedLyrics(lines);
    removedCount++;
    return true;
  }
}

/// Quick per-line timing fix.
///
/// The song and line are captured when the sheet opens: playback keeps
/// running underneath, so a live line index would be the wrong target by the
/// second tap.
class _NudgeLineSheet extends ConsumerStatefulWidget {
  const _NudgeLineSheet({
    required this.filePath,
    required this.unsynced,
    required this.index,
    required this.session,
    required this.title,
    required this.artist,
    this.meaningService,
  });

  final String filePath;
  final UnsyncedLyrics? unsynced;
  final int index;
  final _NudgeSession session;

  /// The song's title and artist: the meaning lookup and the shared
  /// quote need them, and the sheet itself only knows the line.
  final String title;
  final String artist;

  /// Injected for tests; a real service when null.
  final GeniusMeaningService? meaningService;

  @override
  ConsumerState<_NudgeLineSheet> createState() => _NudgeLineSheetState();
}

class _NudgeLineSheetState extends ConsumerState<_NudgeLineSheet> {
  static const _step = Duration(milliseconds: 100);

  late SyncedLyrics _synced;
  late int _index;

  @override
  void initState() {
    super.initState();
    _synced = widget.session.synced;
    _index = widget.index;
  }

  void _nudge(Duration delta) {
    final updated = widget.session.nudge(_index, delta);
    if (updated == null) return;
    setState(() {
      _synced = updated.synced;
      _index = updated.index;
    });
  }

  /// Plays from this line's timestamp, resuming first when paused — the
  /// point is to hear whether the line lands where it should.
  Future<void> _playFromLine() async {
    final timestamp = _line?.timestamp;
    if (timestamp == null) return;
    final service = ref.read(audioPlayerServiceProvider);
    await service.seekTo(timestamp);
    if (!service.isPlaying) await service.play();
  }

  /// Opens the Genius meaning sheet for this line. Neither the lookup
  /// nor the sheet touches the session: no write happens on close.
  Future<void> _openMeaning() async {
    final line = _line;
    if (line == null || line.text.trim().isEmpty) return;
    await showMeaningSheet(
      context,
      title: widget.title,
      artist: widget.artist,
      lineText: line.text,
      service: widget.meaningService,
    );
  }

  /// Shares this line, quoted with its song. The chooser opening is the
  /// feedback; only a failure gets a snackbar.
  Future<void> _shareLine() async {
    final line = _line;
    if (line == null || line.text.trim().isEmpty) return;
    final outcome = await MediaStore.shareText(
      text: shareQuote(
        line: line.text,
        artist: widget.artist,
        title: widget.title,
      ),
      title: widget.title,
    );
    if (outcome != ShareOutcome.opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Partage impossible.')),
      );
    }
  }

  /// Deletes the line — empty ones only — and closes the sheet. The write
  /// happens on close, like a nudge's, with the session marked dirty by the
  /// removal itself.
  void _deleteLine() {
    if (!widget.session.removeLine(_index)) return;
    if (mounted) Navigator.of(context).pop();
  }

  LyricLine? get _line => (_index >= 0 && _index < _synced.lines.length)
      ? _synced.lines[_index]
      : null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final line = _line;
    final timestamp = line?.timestamp;
    // The delete button is for empty lines only: a line with words is never
    // offered for deletion from here — that stays the sync editor's job.
    final isEmptyLine = line != null && line.text.trim().isEmpty;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                line?.text.trim() ?? '',
                textAlign: TextAlign.center,
                style: textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                timestamp == null
                    ? '—'
                    : '[${LrcParser.formatTimestamp(timestamp)}]',
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: timestamp == null ? null : _playFromLine,
                icon: const Icon(Icons.play_arrow),
                label: const Text("Écouter à partir d'ici"),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: timestamp == null ? null : () => _nudge(-_step),
                    icon: const Icon(Icons.remove),
                    label: const Text('100 ms'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: timestamp == null ? null : () => _nudge(_step),
                    icon: const Icon(Icons.add),
                    label: const Text('100 ms'),
                  ),
                ],
              ),
              if (isEmptyLine) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _deleteLine,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Supprimer la ligne'),
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                ),
              ],
              if (!isEmptyLine) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _openMeaning,
                      icon: const Icon(Icons.lightbulb_outline),
                      label: const Text('Signification'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _shareLine,
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('Partager'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
