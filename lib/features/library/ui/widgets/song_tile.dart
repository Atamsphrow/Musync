import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';

class SongTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  /// Lyrics state, shown as a badge. Null hides it — for the places that list
  /// songs without having resolved their tags, like the player queue.
  final LyricsStatus? status;

  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.status,
  });

  String _formatDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: QueryArtworkWidget(
                    id: song.id,
                    type: ArtworkType.AUDIO,
                    artworkWidth: 48,
                    artworkHeight: 48,
                    artworkFit: BoxFit.cover,
                    nullArtworkWidget: Container(
                      width: 48,
                      height: 48,
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.music_note,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${song.artist} • ${song.album}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (status != null) ...[
                  const SizedBox(width: 10),
                  _StatusBadge(status: status!),
                ],
                const SizedBox(width: 10),
                Text(
                  _formatDuration(song.duration),
                  style: textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Icon standing for a lyrics state. Shared with the catalogue's empty states so
/// the same idea never gets two different pictures.
IconData lyricsStatusIcon(LyricsStatus status) => switch (status) {
  LyricsStatus.none => Icons.music_note_outlined,
  LyricsStatus.plain => Icons.notes_rounded,
  LyricsStatus.synced => Icons.lyrics_rounded,
};

/// One-glance marker of what a track already carries.
///
/// The icon and the colour say the same thing on purpose: colour alone would
/// leave the distinction invisible to anyone who can't separate these hues, and
/// the tooltip spells it out for screen readers.
class _StatusBadge extends StatelessWidget {
  final LyricsStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final color = switch (status) {
      LyricsStatus.none => scheme.onSurfaceVariant.withValues(alpha: 0.55),
      LyricsStatus.plain => scheme.tertiary,
      LyricsStatus.synced => scheme.primary,
    };

    return Tooltip(
      message: lyricsStatusDescription(status),
      child: Icon(lyricsStatusIcon(status), size: 18, color: color),
    );
  }
}
