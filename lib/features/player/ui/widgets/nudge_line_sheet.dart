import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/ui/embed_lyrics_action.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';

/// Opens the quick ±100 ms timing sheet for one synced line.
///
/// Each tap nudges the line in the file and refreshes the lyrics providers,
/// so the player screen, the mini-player line and the bubble all follow.
void showNudgeLineSheet(
  BuildContext context,
  WidgetRef ref, {
  required String filePath,
  required SyncedLyrics synced,
  required UnsyncedLyrics? unsynced,
  required int index,
}) {
  showModalBottomSheet<void>(
    context: context,
    builder: (_) => _NudgeLineSheet(
      filePath: filePath,
      synced: synced,
      unsynced: unsynced,
      index: index,
    ),
  );
}

/// Quick per-line timing fix.
///
/// The line's own ±100 ms nudge buttons, saved to the file on every tap — no
/// trip through the full sync editor. The song and line are captured when the
/// sheet opens: playback keeps running underneath, so a live line index would
/// be the wrong target by the second tap.
class _NudgeLineSheet extends ConsumerStatefulWidget {
  const _NudgeLineSheet({
    required this.filePath,
    required this.synced,
    required this.unsynced,
    required this.index,
  });

  final String filePath;
  final SyncedLyrics synced;
  final UnsyncedLyrics? unsynced;
  final int index;

  @override
  ConsumerState<_NudgeLineSheet> createState() => _NudgeLineSheetState();
}

class _NudgeLineSheetState extends ConsumerState<_NudgeLineSheet> {
  static const _step = Duration(milliseconds: 100);

  late SyncedLyrics _synced;
  late int _index;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _synced = widget.synced;
    _index = widget.index;
  }

  Future<void> _nudge(Duration delta) async {
    if (_saving || _index < 0 || _index >= _synced.lines.length) return;
    final line = _synced.lines[_index];
    final timestamp = line.timestamp;
    // Untimed lines never reach SyncedLyrics, but never trust it blindly.
    if (timestamp == null) return;
    setState(() => _saving = true);
    // Floored at zero, like SyncedLyrics.offsetAll.
    final next = timestamp + delta < Duration.zero
        ? Duration.zero
        : timestamp + delta;
    final nudgedLine = line.copyWith(timestamp: next);
    // The constructor re-sorts, so re-locate the line by identity for the
    // next tap instead of trusting the old index.
    final nudged = SyncedLyrics([
      for (var i = 0; i < _synced.lines.length; i++)
        i == _index ? nudgedLine : _synced.lines[i],
    ]);
    final outcome = await embedLyrics(
      context,
      ref,
      filePath: widget.filePath,
      synced: nudged,
      unsynced: widget.unsynced,
      // This sheet owns the whole synced state for the tap, like the sync
      // editor does — a plain-text write must not wipe the timings.
      onPlainOverSynced: PlainOverSynced.replace,
      successMessage:
          '« ${line.text.trim()} » ${delta.isNegative ? '−' : '+'}100 ms.',
    );
    if (!mounted) return;
    if (outcome == EmbedOutcome.written) {
      _synced = nudged;
      _index = nudged.lines.indexOf(nudgedLine);
      // The player screen, the mini-player line and the bubble all read
      // through this provider.
      ref.invalidate(currentLyricsProvider);
    }
    setState(() => _saving = false);
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
                  onPressed: _saving || timestamp == null
                      ? null
                      : () => _nudge(-_step),
                  icon: const Icon(Icons.remove),
                  label: const Text('100 ms'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _saving || timestamp == null
                      ? null
                      : () => _nudge(_step),
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
