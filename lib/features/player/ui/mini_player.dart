import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/router/app_router.dart';
import 'package:musync/features/lyrics/ui/embed_lyrics_action.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';
import 'package:musync/features/settings/providers/lyrics_appearance_provider.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    // Watches the track and nothing else.
    //
    // Rebuilding this widget rebuilds `QueryArtworkWidget`, which re-queries
    // MediaStore for the cover and makes it flash. The position was the obvious
    // culprit and was split out first — but the player *state* also emits on
    // every buffering transition, which is often enough to flicker on a track
    // that is still loading. Both live in their own consumers below, so the
    // artwork is built once per track and no more.
    final currentSong = ref.watch(currentSongProvider);

    if (currentSong == null) return const SizedBox.shrink();

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          final service = ref.read(audioPlayerServiceProvider);
          Navigator.pushNamed(
            context,
            AppRoutes.player,
            // Passing the live queue means reopening the player never restarts
            // playback — it recognises the song as the one already playing.
            arguments: SongRouteArgs(
              song: currentSong,
              queue: service.queue,
              index: service.currentIndex,
            ),
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _MiniProgressBar(),
            // The current synced line, right under the progress bar — the
            // inline replacement for the floating bubble inside the app.
            // Collapses when there is no active line, so the player keeps its
            // compact height on lyrics-less songs.
            const _MiniLyricLine(),
            const SizedBox(
              height: 62,
              child: _MiniContentRow(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The cover + title/artist + play/pause row, in its own widget so the lyric
/// line above can rebuild on every line change without re-querying the cover.
class _MiniContentRow extends ConsumerWidget {
  const _MiniContentRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // Watches the track and nothing else.
    //
    // Rebuilding this widget rebuilds `QueryArtworkWidget`, which re-queries
    // MediaStore for the cover and makes it flash. The position was the obvious
    // culprit and was split out first — but the player *state* also emits on
    // every buffering transition, which is often enough to flicker on a track
    // that is still loading. Both live in their own consumers below, so the
    // artwork is built once per track and no more.
    final currentSong = ref.watch(currentSongProvider);

    if (currentSong == null) return const SizedBox.shrink();

    return Row(
      children: [
        const SizedBox(width: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: QueryArtworkWidget(
            id: currentSong.id,
            type: ArtworkType.AUDIO,
            artworkWidth: 44,
            artworkHeight: 44,
            artworkFit: BoxFit.cover,
            // 44 dp is about 176 real pixels at 4x, so the 200 px
            // default is only just enough and shows it. Cheap to
            // ask for a little more at this size.
            size: 256,
            quality: 90,
            artworkQuality: FilterQuality.medium,
            // Holds the previous image while a new one loads, so a
            // track change fades rather than blinks through empty.
            keepOldArtwork: true,
            nullArtworkWidget: Container(
              width: 44,
              height: 44,
              color: scheme.surfaceContainerHighest,
              child: Icon(
                Icons.music_note,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                currentSong.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                currentSong.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const _MiniPlayPauseButton(),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// The current synced lyric line under the progress bar.
///
/// Own consumer: the line index emits on every line change, and rebuilding
/// the cover on each of those would make it flash. Song-tagged like the
/// bubble — while the next track's lyrics load, the provider still holds the
/// previous track's, and showing its line under the new song would be wrong.
class _MiniLyricLine extends ConsumerWidget {
  const _MiniLyricLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;

    final song = ref.watch(currentSongProvider);
    final pair = ref.watch(currentLyricsProvider).valueOrNull;
    final synced = pair?.song?.id == song?.id ? pair?.synced : null;
    final index = ref.watch(currentLineIndexProvider).valueOrNull;
    final text = (synced != null &&
            index != null &&
            index >= 0 &&
            index < synced.lines.length)
        ? synced.lines[index].text.trim()
        : null;
    if (text == null || text.isEmpty) return const SizedBox.shrink();

    // Follows the Apparence settings — color, italic, serif, alignment —
    // all except the size, which stays mini-player small.
    final appearance = ref.watch(lyricsAppearanceProvider);
    final textAlign = switch (appearance.textAlign) {
      LyricsTextAlign.left => TextAlign.left,
      LyricsTextAlign.center => TextAlign.center,
      LyricsTextAlign.right => TextAlign.right,
    };
    final line = Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 16, 1),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
        style: textTheme.bodySmall?.copyWith(
          color: lyricsActiveColor(context, appearance),
          fontStyle:
              appearance.italic ? FontStyle.italic : FontStyle.normal,
          fontFamily:
              appearance.fontStyle == LyricsFontStyle.stylized ? 'serif' : null,
        ),
      ),
    );
    // Long-press: nudge this line's timing directly, without opening the
    // full sync editor. Taps still fall through to the mini-player's own
    // handler (this detector only claims the long-press).
    if (song == null || synced == null || index == null) return line;
    return GestureDetector(
      onLongPress: () => _showNudgeSheet(
        context,
        ref,
        filePath: song.filePath,
        synced: synced,
        unsynced: pair?.unsynced,
        index: index,
      ),
      child: line,
    );
  }
}

/// Opens the quick ±100 ms timing sheet for one synced line.
void _showNudgeSheet(
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

/// Quick per-line timing fix, straight from the mini-player.
///
/// The line's own ±100 ms nudge buttons, saved to the file on every tap — no
/// trip through the full sync editor. The song and line are captured when the
/// sheet opens: playback keeps running underneath, so the live line index
/// would be the wrong target by the second tap.
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
      // The mini-player line, the bubble and the player screen all read
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

/// The play/pause button, in its own consumer for the same reason as the bar.
class _MiniPlayPauseButton extends ConsumerWidget {
  const _MiniPlayPauseButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isPlaying = ref.watch(playerStateProvider).value?.playing ?? false;

    return IconButton(
      icon: Icon(
        isPlaying ? Icons.pause : Icons.play_arrow,
        color: scheme.onSurface,
      ),
      tooltip: isPlaying ? 'Pause' : 'Lecture',
      onPressed: () {
        HapticFeedback.lightImpact();
        final service = ref.read(audioPlayerServiceProvider);
        unawaited(isPlaying ? service.pause() : service.play());
      },
    );
  }
}

/// The one part that has to follow the playhead.
///
/// Split out so the rest of the mini player — the cover above all — is not
/// rebuilt several times a second for a two-pixel bar.
class _MiniProgressBar extends ConsumerWidget {
  const _MiniProgressBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = ref.watch(durationProvider).value ?? Duration.zero;

    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return LinearProgressIndicator(
      value: progress,
      backgroundColor: scheme.surfaceContainerHighest,
      color: scheme.primary,
      minHeight: 2,
    );
  }
}
