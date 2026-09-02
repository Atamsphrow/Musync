import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:musync/core/router/app_router.dart';
import 'package:musync/features/player/providers/player_provider.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

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
        child: SizedBox(
          height: 66,
          child: Column(
            children: [
              const _MiniProgressBar(),
              Expanded(
                child: Row(
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
                ),
              ),
            ],
          ),
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
      onPressed: () {
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
