import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/router/app_router.dart';
import 'package:musync/core/theme/app_theme.dart';
import 'package:musync/core/theme/artwork_scheme_provider.dart';
import 'package:musync/core/utils/duration_format.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/ui/widgets/player_controls.dart';
import 'package:musync/features/player/ui/widgets/synced_lyrics_view.dart';

/// Full-screen now-playing view.
///
/// Re-tints itself from the cover art of whatever is playing — the second half
/// of the Material You story, the first being the wallpaper palette the rest of
/// the app follows.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  bool _showLyrics = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Route arguments aren't readable until the route is in the tree, and this
    // must not re-fire on every dependency change or reopening the screen would
    // restart the track.
    if (_started) return;
    _started = true;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is! SongRouteArgs) return;

    if (ref.read(currentSongProvider) != args.song) {
      ref.read(audioPlayerServiceProvider).playSong(
            args.song,
            queue: args.queue,
            index: args.index,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = ref.watch(currentSongProvider);
    final baseScheme = Theme.of(context).colorScheme;

    // Falls back to the app scheme for tracks with no embedded art.
    final artworkScheme = song == null
        ? null
        : ref
            .watch(artworkSchemeProvider(ArtworkSchemeRequest(
              songId: song.id,
              brightness: baseScheme.brightness,
            )))
            .valueOrNull;

    return AnimatedTheme(
      data: AppTheme.fromScheme(artworkScheme ?? baseScheme),
      duration: const Duration(milliseconds: 500),
      child: Builder(
        builder: (context) => _buildContent(context, song),
      ),
    );
  }

  Widget _buildContent(BuildContext context, Song? song) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              song: song,
              showLyrics: _showLyrics,
              onToggleLyrics: () => setState(() => _showLyrics = !_showLyrics),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _showLyrics
                    ? _LyricsPane(song: song, key: const ValueKey('lyrics'))
                    : _ArtworkPane(song: song, key: const ValueKey('artwork')),
              ),
            ),
            if (song != null) _SongTitle(song: song),
            const SizedBox(height: 8),
            _SeekBar(song: song),
            const SizedBox(height: 4),
            const PlayerControls(),
            const SizedBox(height: 8),
            _LyricsActions(song: song),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final Song? song;
  final bool showLyrics;
  final VoidCallback onToggleLyrics;

  const _TopBar({
    required this.song,
    required this.showLyrics,
    required this.onToggleLyrics,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            tooltip: 'Réduire',
            onPressed: () => Navigator.maybePop(context),
          ),
          Expanded(
            child: Text(
              'Lecture en cours',
              textAlign: TextAlign.center,
              style: textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            isSelected: showLyrics,
            icon: const Icon(Icons.lyrics_outlined),
            selectedIcon: const Icon(Icons.lyrics),
            tooltip: showLyrics ? 'Afficher la pochette' : 'Afficher les paroles',
            onPressed: song == null ? null : onToggleLyrics,
          ),
        ],
      ),
    );
  }
}

class _ArtworkPane extends StatelessWidget {
  final Song? song;

  const _ArtworkPane({super.key, required this.song});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: AspectRatio(
          aspectRatio: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.35),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: song == null
                  ? ColoredBox(color: scheme.surfaceContainerHighest)
                  : QueryArtworkWidget(
                      id: song!.id,
                      type: ArtworkType.AUDIO,
                      artworkQuality: FilterQuality.high,
                      artworkFit: BoxFit.cover,
                      artworkBorder: BorderRadius.zero,
                      keepOldArtwork: true,
                      nullArtworkWidget: ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.music_note,
                          size: 96,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Karaoke pane. Empty and error states send the user to the online search
/// rather than leaving them on a blank screen (plan §3.2).
class _LyricsPane extends ConsumerWidget {
  final Song? song;

  const _LyricsPane({super.key, required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final lyricsAsync = ref.watch(currentLyricsProvider);

    void searchOnline() {
      if (song == null) return;
      Navigator.pushNamed(
        context,
        AppRoutes.lyricsSearch,
        arguments: SongRouteArgs(song: song!),
      );
    }

    return lyricsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Text(
          'Lecture des paroles impossible.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ),
      data: (pair) {
        final synced = pair.synced;
        if (synced != null && synced.isNotEmpty) {
          return SyncedLyricsView(
            lyrics: synced,
            onSearchOnline: searchOnline,
          );
        }

        // Plain lyrics still beat nothing — shown unscrolled, since there is
        // no timing to follow.
        final plain = pair.unsynced;
        if (plain != null && plain.isNotEmpty) {
          return _PlainLyrics(text: plain.text, onSearchOnline: searchOnline);
        }

        // Nothing embedded at all — the empty state of SyncedLyricsView is the
        // "no lyrics, here's what you can do" screen.
        return SyncedLyricsView(
          lyrics: SyncedLyrics.empty(),
          onSearchOnline: searchOnline,
        );
      },
    );
  }
}

class _PlainLyrics extends StatelessWidget {
  final String text;
  final VoidCallback onSearchOnline;

  const _PlainLyrics({required this.text, required this.onSearchOnline});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge?.copyWith(color: scheme.onSurface),
            ),
          ),
        ),
        TextButton.icon(
          onPressed: onSearchOnline,
          icon: const Icon(Icons.search, size: 18),
          label: const Text('Chercher une version synchronisée'),
        ),
      ],
    );
  }
}

class _SongTitle extends StatelessWidget {
  final Song song;

  const _SongTitle({required this.song});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: textTheme.headlineSmall?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Seek bar that commits once, on release — see the note in the sync editor's
/// copy: seeking per pixel makes the platform player stutter.
class _SeekBar extends ConsumerStatefulWidget {
  final Song? song;

  const _SeekBar({required this.song});

  @override
  ConsumerState<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<_SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration = ref.watch(durationProvider).valueOrNull ??
        widget.song?.durationValue ??
        Duration.zero;

    final max = duration.inMilliseconds.toDouble();
    final value =
        (_dragValue ?? position.inMilliseconds.toDouble()).clamp(0.0, max);

    final labelStyle = textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Slider(
            value: value,
            // A zero max would make Slider throw before the duration arrives.
            max: max <= 0 ? 1 : max,
            onChanged:
                max <= 0 ? null : (v) => setState(() => _dragValue = v),
            onChangeEnd: (v) {
              ref
                  .read(audioPlayerServiceProvider)
                  .seekTo(Duration(milliseconds: v.toInt()));
              setState(() => _dragValue = null);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatClock(Duration(milliseconds: value.toInt())),
                    style: labelStyle),
                Text(formatClock(duration), style: labelStyle),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The lyrics actions of plan §3.3, gathered in one sheet.
class _LyricsActions extends ConsumerWidget {
  final Song? song;

  const _LyricsActions({required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TextButton.icon(
          onPressed: song == null ? null : () => _openSheet(context),
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('Paroles'),
        ),
      ],
    );
  }

  void _openSheet(BuildContext context) {
    final target = song!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: const Text('Rechercher des paroles en ligne'),
              subtitle: const Text('LRCLIB — paroles synchronisées'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.pushNamed(
                  context,
                  AppRoutes.lyricsSearch,
                  arguments: SongRouteArgs(song: target),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Ajuster la synchronisation'),
              subtitle: const Text('Caler chaque ligne sur la lecture'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.pushNamed(
                  context,
                  AppRoutes.syncEditor,
                  arguments: SongRouteArgs(song: target),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Éditer le texte des paroles'),
              subtitle: const Text('Saisie ou collage manuel'),
              onTap: () {
                Navigator.pop(sheetContext);
                // Same screen — its "Simple" tab is the plain-text editor.
                Navigator.pushNamed(
                  context,
                  AppRoutes.syncEditor,
                  arguments: SongRouteArgs(song: target),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
