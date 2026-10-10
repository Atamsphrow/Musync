import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/ui/embed_lyrics_action.dart';

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
}) async {
  final session = _NudgeSession(initialSynced: synced);
  await showModalBottomSheet<void>(
    context: context,
    builder: (_) => _NudgeLineSheet(
      filePath: filePath,
      unsynced: unsynced,
      index: index,
      session: session,
    ),
  );
  if (!session.dirty) return;
  if (!context.mounted) return;
  final totalMs = session.totalDelta.inMilliseconds.abs();
  await embedLyrics(
    context,
    ref,
    filePath: filePath,
    synced: session.synced,
    unsynced: unsynced,
    // This sheet owns the whole synced state for the session, like the sync
    // editor does — a plain-text write must not wipe the timings.
    onPlainOverSynced: PlainOverSynced.replace,
    successMessage:
        '« ${session.lineText} » ${session.totalDelta.isNegative ? '−' : '+'}$totalMs ms.',
  );
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

  /// The line's text at the last tap, for the summary snackbar.
  String lineText = '';

  bool get dirty => totalDelta != Duration.zero;

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
  });

  final String filePath;
  final UnsyncedLyrics? unsynced;
  final int index;
  final _NudgeSession session;

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

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final line = (_index >= 0 && _index < _synced.lines.length)
        ? _synced.lines[_index]
        : null;
    final timestamp = line?.timestamp;
    return SafeArea(
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
          ],
        ),
      ),
    );
  }
}
