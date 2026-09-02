import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';

/// Karaoke-style lyrics: the active line is highlighted and kept centered
/// while the track plays. Tapping a line seeks to it.
class SyncedLyricsView extends ConsumerStatefulWidget {
  final SyncedLyrics lyrics;
  final VoidCallback? onSearchOnline;

  const SyncedLyricsView({
    super.key,
    required this.lyrics,
    this.onSearchOnline,
  });

  @override
  ConsumerState<SyncedLyricsView> createState() => _SyncedLyricsViewState();
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

    // The list carries `viewportHeight / 2` of padding at each end, which is
    // what lets the first and last lines reach the middle of the screen at all.
    // Line `index` therefore starts at `viewportHeight / 2 + index * extent`,
    // and centring its midpoint means scrolling to:
    //
    //     (viewportHeight / 2 + index * extent + extent / 2) - viewportHeight / 2
    //
    // which is simply `index * extent + extent / 2` — the two halves cancel.
    //
    // The previous version subtracted the half-viewport without adding the
    // padding back, landing half a screen short every time. That is why the
    // active line drifted to the bottom edge and stuck there.
    final target = (index * _lineExtent) + (_lineExtent / 2);

    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currentIndex = ref.watch(currentLineIndexProvider).valueOrNull;

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
          padding: EdgeInsets.symmetric(vertical: constraints.maxHeight / 2),
          itemBuilder: (context, index) {
            final line = widget.lyrics.lines[index];
            final isCurrent = index == currentIndex;
            final isPast = currentIndex != null && index < currentIndex;

            final Color color;
            if (isCurrent) {
              color = scheme.primary;
            } else if (isPast) {
              color = scheme.onSurfaceVariant;
            } else {
              color = scheme.onSurfaceVariant.withValues(alpha: 0.45);
            }

            return InkWell(
              // Non-null: this view renders SyncedLyrics, which is timed-only.
              onTap: () =>
                  ref.read(audioPlayerServiceProvider).seekTo(line.timestamp!),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Center(
                  child: AnimatedDefaultTextStyle(
                    // Short on purpose, and it is the other half of T22: the
                    // detection is now exact to the frame, but a quarter-second
                    // cross-fade on the colour and the weight still reads as
                    // lag. The scroll below keeps its 400 ms — that one is
                    // motion, and motion is allowed to be smooth.
                    duration: const Duration(milliseconds: 120),
                    style:
                        (isCurrent
                                ? textTheme.titleMedium
                                : textTheme.bodyLarge)!
                            .copyWith(
                              color: color,
                              fontWeight: isCurrent
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            ),
                    textAlign: TextAlign.center,
                    child: Text(
                      line.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
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
