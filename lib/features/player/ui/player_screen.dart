import 'package:flutter/material.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/router/app_router.dart';
import 'package:musync/core/theme/app_theme.dart';
import 'package:musync/core/theme/artwork_scheme_provider.dart';
import 'package:musync/core/utils/duration_format.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/ui/widgets/player_controls.dart';
import 'package:musync/features/player/ui/widgets/marquee_text.dart';
import 'package:musync/features/player/ui/widgets/synced_lyrics_view.dart';
import 'package:musync/features/sync_editor/providers/sync_editor_provider.dart';

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

  void _toggleLyrics() => setState(() => _showLyrics = !_showLyrics);

  // ── Swipe down to minimise (T8) ──
  //
  // Bound to the top bar and the artwork rather than the whole screen: the
  // lyrics pane scrolls, and a page that closed itself on a scroll gesture
  // would be unusable exactly where the user reads longest.

  /// How far the screen has been dragged down, in logical pixels.
  ///
  /// The screen follows the finger. The first version only watched the release
  /// velocity, so nothing moved while dragging and a slow, deliberate pull did
  /// nothing at all — the gesture read as broken rather than as unavailable.
  double _dragOffset = 0;

  /// Distance past which letting go dismisses, however slowly the finger moved.
  static const double _dismissDistance = 110;

  /// Release speed that dismisses on its own, for a quick flick that never
  /// travels far. Lower than it was: 300 px/s is a brisk gesture, not a casual
  /// one.
  static const double _dismissVelocity = 180;

  void _onDragUpdate(DragUpdateDetails details) {
    // Downward only. Dragging up on a screen that cannot go up should do
    // nothing rather than rubber-band.
    setState(
      () => _dragOffset = (_dragOffset + details.delta.dy).clamp(0, 400),
    );
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dragOffset >= _dismissDistance || velocity >= _dismissVelocity) {
      Navigator.maybePop(context);
      return;
    }
    // Not far enough: snap back, so an abandoned gesture leaves no trace.
    setState(() => _dragOffset = 0);
  }

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
      ref
          .read(audioPlayerServiceProvider)
          .playSong(args.song, queue: args.queue, index: args.index);
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
              .watch(
                artworkSchemeProvider(
                  ArtworkSchemeRequest(
                    songId: song.id,
                    brightness: baseScheme.brightness,
                  ),
                ),
              )
              .valueOrNull;

    return AnimatedTheme(
      data: AppTheme.fromScheme(artworkScheme ?? baseScheme),
      duration: const Duration(milliseconds: 500),
      child: Builder(builder: (context) => _buildContent(context, song)),
    );
  }

  Widget _buildContent(BuildContext context, Song? song) {
    final scheme = Theme.of(context).colorScheme;

    // P8 / T6. The rule is asymmetric, and the asymmetry is the point.
    //
    // Going *in* by tapping the artwork works for every track, whatever it
    // carries — that is how Musicolet behaves and how a cover reads: as a
    // button to the words behind it.
    //
    // Coming *back* by tapping the lyrics only works when they are plain. A
    // synchronised pane scrolls and follows the music, so a tap on it means
    // "let me look at this", not "take me away"; the top-bar button is the way
    // out there.
    final hasSyncedLyrics =
        ref.watch(currentLyricsProvider).valueOrNull?.synced != null;
    final tapOnLyrics = hasSyncedLyrics ? null : _toggleLyrics;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Transform.translate(
        offset: Offset(0, _dragOffset),
        child: SafeArea(
          child: Column(
            children: [
              GestureDetector(
                onVerticalDragUpdate: _onDragUpdate,
                onVerticalDragEnd: _onDragEnd,
                child: _TopBar(
                  song: song,
                  showLyrics: _showLyrics,
                  onToggleLyrics: _toggleLyrics,
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _showLyrics
                      ? GestureDetector(
                          key: const ValueKey('lyrics'),
                          // Opaque, so the whole pane answers — not only the
                          // pixels a child happens to occupy. The default
                          // (`deferToChild`) meant that on a track with no
                          // lyrics, where the pane is mostly empty space around
                          // a "Chercher en ligne" button, tapping anywhere but
                          // that button did nothing and there was no way back
                          // to the cover.
                          //
                          // The button still wins: a child's gesture is
                          // resolved before its parent's.
                          behavior: HitTestBehavior.opaque,
                          onTap: tapOnLyrics,
                          child: _LyricsPane(song: song),
                        )
                      : _ArtworkPane(
                          song: song,
                          key: const ValueKey('artwork'),
                          // Always available: every track's cover opens its words.
                          onTap: song == null ? null : _toggleLyrics,
                          onVerticalDragUpdate: _onDragUpdate,
                          onVerticalDragEnd: _onDragEnd,
                        ),
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
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Ouvrir dans Musicolet',
            onPressed: song == null ? null : () => _share(context, song!),
          ),
          IconButton(
            isSelected: showLyrics,
            icon: const Icon(Icons.lyrics_outlined),
            selectedIcon: const Icon(Icons.lyrics),
            tooltip: showLyrics
                ? 'Afficher la pochette'
                : 'Afficher les paroles',
            onPressed: song == null ? null : onToggleLyrics,
          ),
        ],
      ),
    );
  }
}

/// Sends the track to another app — Musicolet, above all.
///
/// The reason it is here rather than buried in a menu: the loop this app is
/// built around is write the lyrics, then check they show up somewhere else.
/// Making that a single tap from the now-playing screen is the difference
/// between checking your work and assuming it is fine.
Future<void> _share(BuildContext context, Song song) async {
  final messenger = ScaffoldMessenger.of(context);

  // Straight to Musicolet, no chooser.
  //
  // The sheet never listed it: a share needs the other app to declare a share
  // receiver, and a music player declares a handler for *opening* audio
  // instead. Naming the package uses that handler — and skips a chooser that
  // was, for this one purpose, only ever in the way.
  final outcome = await MediaStore.shareAudio(
    mediaStoreId: song.id,
    title: song.title,
    targetPackage: MediaStore.musicoletPackage,
  );

  switch (outcome) {
    case ShareOutcome.opened:
      return;
    case ShareOutcome.appNotInstalled:
      // Falls back to the sheet rather than dead-ending: without Musicolet the
      // user still has whatever else can open an audio file.
      messenger.showOnly(
        SnackBar(
          content: const Text("Musicolet n'est pas installé."),
          action: SnackBarAction(
            label: 'Autre app',
            onPressed: () =>
                MediaStore.shareAudio(mediaStoreId: song.id, title: song.title),
          ),
        ),
      );
    case ShareOutcome.failed:
      messenger.showOnly(
        const SnackBar(content: Text('Ouverture impossible pour ce morceau.')),
      );
  }
}

class _ArtworkPane extends StatelessWidget {
  final Song? song;

  /// Reveals the lyrics. Null only while there is no track to show any for.
  final VoidCallback? onTap;

  /// Swipe-down-to-minimise. The cover is the largest safe surface for it —
  /// nothing under it scrolls.
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const _ArtworkPane({
    super.key,
    required this.song,
    this.onTap,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: GestureDetector(
          onTap: onTap,
          onVerticalDragUpdate: onVerticalDragUpdate,
          onVerticalDragEnd: onVerticalDragEnd,
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
                        // `on_audio_query` defaults to a 200 px JPEG at
                        // quality 50. This pane is a full-width square: on a
                        // 3x screen that is around 900 real pixels, so the
                        // default was a thumbnail stretched to four times its
                        // size — which is exactly why the cover looked soft
                        // here and sharp in players that read the embedded
                        // image at its own resolution. 1024 covers 3x on the
                        // widest phone; asking for more would only cost
                        // memory.
                        size: 1024,
                        quality: 100,
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
      ),
    );
  }
}

/// Karaoke pane. Empty and error states send the user to the online search
/// rather than leaving them on a blank screen (plan §3.2).
class _LyricsPane extends ConsumerWidget {
  final Song? song;

  // No key: the AnimatedSwitcher keys the GestureDetector wrapping this pane,
  // since that is the child it actually swaps.
  const _LyricsPane({required this.song});

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
          return SyncedLyricsView(lyrics: synced, onSearchOnline: searchOnline);
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
          // Scrolls when the name is longer than the screen, which for a
          // library built from downloads is most of the time — and an ellipsis
          // hides precisely the part that says which version this is.
          MarqueeText(
            text: song.title,
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
    final duration =
        ref.watch(durationProvider).valueOrNull ??
        widget.song?.durationValue ??
        Duration.zero;

    final max = duration.inMilliseconds.toDouble();
    final value = (_dragValue ?? position.inMilliseconds.toDouble()).clamp(
      0.0,
      max,
    );

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
            onChanged: max <= 0 ? null : (v) => setState(() => _dragValue = v),
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
                Text(
                  formatClock(Duration(milliseconds: value.toInt())),
                  style: labelStyle,
                ),
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
          onPressed: song == null ? null : () => _openSheet(context, ref),
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('Paroles'),
        ),
      ],
    );
  }

  void _openSheet(BuildContext context, WidgetRef ref) {
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
              subtitle: const Text(
                'LRCLIB pour les paroles calées, lyrics.ovh pour le texte',
              ),
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
                  arguments: SongRouteArgs(
                    song: target,
                    editorMode: SyncMode.synced,
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Éditer le texte des paroles'),
              subtitle: const Text('Saisie ou collage manuel'),
              onTap: () {
                Navigator.pop(sheetContext);
                // The same screen, but opened on its plain-text half. The two
                // entries used to land identically, which made one of them
                // look broken (T4).
                Navigator.pushNamed(
                  context,
                  AppRoutes.syncEditor,
                  arguments: SongRouteArgs(
                    song: target,
                    editorMode: SyncMode.simple,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
