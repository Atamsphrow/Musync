import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:musync/core/router/app_router.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/frame_probe.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';
import 'package:musync/features/settings/providers/lyrics_appearance_provider.dart';

class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key, required this.onLongPress});

  /// Fired when the long-press timer completes (the tap that follows is
  /// swallowed by [_MiniPlayerState]). The library screen passes its
  /// locate-the-playing-track routine here — a direct callback, no provider
  /// round-trip.
  final Future<void> Function() onLongPress;

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  /// Set when the long-press timer fires: the tap the gesture arena still
  /// delivers on release must then be swallowed, so a long-press never opens
  /// the player. Reset on every new press (a press that slides away after
  /// the timer fired delivers no tap — without the reset the flag would
  /// wrongly swallow the *next* tap).
  bool _suppressNextTap = false;

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
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

    // The long-press is detected by _LongPressListener below, outside the
    // gesture arena: InkWell's own onLongPress never fired on device (the tap
    // wins the arena, the 500 ms press does not survive it). The Listener
    // sees raw pointer events and cannot lose the arena, so the gesture
    // works anywhere on the mini player. The tap the arena still delivers
    // on release after a long-press is swallowed via _suppressNextTap, so a
    // long-press never opens the player on top of the locate.
    return _LongPressListener(
      onPressStart: () => _suppressNextTap = false,
      onLongPress: () {
        _suppressNextTap = true;
        DebugLog.instance.info('Appui long', 'geste détecté sur le mini-lecteur');
        HapticFeedback.lightImpact();
        unawaited(widget.onLongPress());
      },
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (_suppressNextTap) {
              _suppressNextTap = false;
              return;
            }
            // TEMPORARY (chasse au gel) : 120 frames couvrent la glissade
            // de 350 ms même à 120 Hz.
            FrameProbe.start('ouverture mini', frames: 120);
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
      ),
    );
  }
}

/// Detects a long-press anywhere in its subtree without entering Flutter's
/// gesture arena.
///
/// A [Listener] receives raw pointer events and can neither win nor lose
/// against another recognizer, so unlike InkWell's onLongPress it cannot be
/// starved by a competing gesture. A 500 ms timer with an 18 px move
/// tolerance (kTouchSlop) implements the press; release, cancel or a slide
/// aborts it. The child's own gestures (InkWell.onTap, icon buttons) keep
/// working untouched — the parent swallows the post-long-press tap itself
/// via [onPressStart]/a flag if needed.
class _LongPressListener extends StatefulWidget {
  const _LongPressListener({
    required this.onLongPress,
    required this.onPressStart,
    required this.child,
  });

  final VoidCallback onLongPress;

  /// Called synchronously on every pointer-down, before the timer starts.
  final VoidCallback onPressStart;
  final Widget child;

  @override
  State<_LongPressListener> createState() => _LongPressListenerState();
}

class _LongPressListenerState extends State<_LongPressListener> {
  static const _delay = Duration(milliseconds: 500);
  static const _slop = 18.0;

  Timer? _timer;
  Offset? _start;

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _start = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        widget.onPressStart();
        _timer?.cancel();
        _start = e.position;
        _timer = Timer(_delay, () {
          _timer = null;
          if (mounted) widget.onLongPress();
        });
      },
      onPointerMove: (e) {
        final s = _start;
        if (s != null && (e.position - s).distance > _slop) _cancel();
      },
      onPointerUp: (_) => _cancel(),
      onPointerCancel: (_) => _cancel(),
      child: widget.child,
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
    return line;
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

    // RepaintBoundary: the bar ticks ~5×/s from the playback position.
    // Without its own boundary, each tick re-records everything up to
    // the route's boundary — the whole library page behind it — for a
    // 2 px strip. The indicator alone repaints now.
    return RepaintBoundary(
      child: LinearProgressIndicator(
        value: progress,
        backgroundColor: scheme.surfaceContainerHighest,
        color: scheme.primary,
        minHeight: 2,
      ),
    );
  }
}
