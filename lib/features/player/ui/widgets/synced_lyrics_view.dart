import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/ui/widgets/nudge_line_sheet.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';
import 'package:musync/features/settings/providers/lyrics_appearance_provider.dart';
import 'package:musync/features/library/data/models/song.dart';

/// Karaoke-style lyrics: the active line is highlighted and kept centered
/// while the track plays. Tapping a line seeks to it.
class SyncedLyricsView extends ConsumerStatefulWidget {
  final SyncedLyrics lyrics;
  final VoidCallback? onSearchOnline;

  /// The currently playing song. Required for the long-press action, which
  /// nudges the pressed line's timing straight in the file. Null only when the
  /// view is shown without a player behind it (preview, etc).
  final Song? song;

  /// The track's plain lyrics, passed through untouched when the long-press
  /// nudge rewrites the timings.
  final UnsyncedLyrics? unsynced;

  const SyncedLyricsView({
    super.key,
    required this.lyrics,
    this.onSearchOnline,
    this.song,
    this.unsynced,
  });

  @override
  ConsumerState<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

/// Builds the line style from the user's appearance settings. The system
/// serif keeps the APK free of a bundled font; on Android it resolves to
/// Noto Serif Italic.
TextStyle _lyricsTextStyle(TextStyle? base, LyricsAppearance appearance) {
  var style = base!;
  if (appearance.fontStyle == LyricsFontStyle.stylized) {
    style = style.copyWith(fontFamily: 'serif');
  }
  if (appearance.italic) {
    style = style.copyWith(fontStyle: FontStyle.italic);
  }
  return style.copyWith(fontSize: (style.fontSize ?? 16) * appearance.fontScale);
}

class _SyncedLyricsViewState extends ConsumerState<SyncedLyricsView> {
  // Measuring every line would mean laying the whole song out up front, so
  // lines are given a fixed extent instead — that also makes centering exact
  // rather than the running approximation it would otherwise be.
  static const double _lineExtent = 56;

  final ScrollController _scrollController = ScrollController();
  int? _lastCenteredIndex;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _centerLine(int index, double viewportHeight) {
    if (_lastCenteredIndex == index) return;
    if (!_scrollController.hasClients) return;
    _lastCenteredIndex = index;

    // No end padding: the list is a plain list, so the first line rests at
    // the very top and the last at the very bottom — never floating mid-screen.
    // Centring a line's midpoint means scrolling to:
    //
    //     index * extent + extent / 2 - viewportHeight / 2
    //
    // clamped to what the list can actually scroll.
    final target =
        (index * _lineExtent) + (_lineExtent / 2) - (viewportHeight / 2);

    // One fixed, quick glide per line: 250 ms, ease-out. Measured
    // frame-by-frame on Musicolet's lyrics view: the step starts fast and
    // settles softly, which is ease-out, not ease-in-out.
    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void didUpdateWidget(covariant SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new song (or retimed lyrics) must not inherit the old scroll anchor:
    // the next line change re-centres from wherever the list happens to be.
    if (oldWidget.lyrics != widget.lyrics) _lastCenteredIndex = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currentIndex = ref.watch(currentLineIndexProvider).valueOrNull;
    final appearance = ref.watch(lyricsAppearanceProvider);
    final textAlign = switch (appearance.textAlign) {
      LyricsTextAlign.left => TextAlign.left,
      LyricsTextAlign.center => TextAlign.center,
      LyricsTextAlign.right => TextAlign.right,
    };

    if (widget.lyrics.isEmpty) {
      return _EmptyLyrics(onSearchOnline: widget.onSearchOnline);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (currentIndex != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _centerLine(currentIndex, constraints.maxHeight);
          });
        }

        return ListView.builder(
          controller: _scrollController,
          itemCount: widget.lyrics.length,
          itemExtent: _lineExtent,
          itemBuilder: (context, index) {
            final line = widget.lyrics.lines[index];
            final isCurrent = index == currentIndex;

            // The active line is bold in the chosen color, everything else
            // the same dim grey — no past/future split.
            final Color color = isCurrent
                ? lyricsActiveColor(context, appearance)
                : scheme.onSurfaceVariant.withValues(alpha: 0.55);

            return InkWell(
              // Non-null: this view renders SyncedLyrics, which is timed-only.
              onTap: () =>
                  ref.read(audioPlayerServiceProvider).seekTo(line.timestamp!),
              // Long-press: nudge this line's timing directly (±100 ms),
              // without opening the full sync editor. The editor stays
              // available from the player's "Ajuster la synchronisation"
              // menu entry.
              onLongPress: widget.song == null
                  ? null
                  : () => showNudgeLineSheet(
                        context,
                        ref,
                        filePath: widget.song!.filePath,
                        synced: widget.lyrics,
                        unsynced: widget.unsynced,
                        index: index,
                      ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Center(
                  child: AnimatedDefaultTextStyle(
                    // Short on purpose, and it is the other half of T22: the
                    // detection is now exact to the frame, but a quarter-second
                    // cross-fade on the colour and the weight still reads as
                    // lag. The scroll below keeps its 500 ms — that one is
                    // motion, and motion is allowed to be smooth.
                    duration: const Duration(milliseconds: 120),
                    style: _lyricsTextStyle(textTheme.bodyLarge, appearance)
                        .copyWith(
                      color: color,
                      fontWeight:
                          isCurrent ? FontWeight.w700 : FontWeight.w400,
                    ),
                    textAlign: textAlign,
                    child: Text(
                      line.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: textAlign,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _EmptyLyrics extends StatelessWidget {
  final VoidCallback? onSearchOnline;

  const _EmptyLyrics({this.onSearchOnline});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lyrics_outlined,
            size: 56,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Aucune parole pour ce morceau',
            style: textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (onSearchOnline != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onSearchOnline,
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Rechercher en ligne'),
            ),
          ],
        ],
      ),
    );
  }
}
