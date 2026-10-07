import 'dart:async';
import 'dart:io' show File, FileStat, FileSystemEntityType, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/core/router/app_router.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/library/ui/widgets/song_tile.dart';
import 'package:musync/features/lyrics/ui/batch_screen.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/ui/queues_sheet.dart';
import 'package:musync/features/player/ui/mini_player.dart';

/// Home screen: the whole music library, plus the mini player docked at the
/// bottom once something is playing.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  /// Owned here rather than left to DefaultTabController.
  ///
  /// A swipe has to move the indicator as well as the list, and
  /// `DefaultTabController.initialIndex` only applies once — changing the
  /// provider left the underline behind on the tab the user had come from.
  late final TabController _tabController;

  /// Owned by the State, created once and disposed once.
  ///
  /// A controller built in `build` is a new object on every frame, and the old
  /// one gets disposed while the field it drives is still mounted — which is
  /// the `_dependents.isEmpty` assertion, not a typing bug.
  late final TextEditingController _searchController;

  /// Focus of the search field. Without this, dismissing the keyboard (system
  /// back button) leaves the field focused: the cursor keeps blinking and
  /// the outline stays blue on a field the user is done with. Taps outside
  /// are handled by the field's own `onTapOutside`; the back-button case is
  /// caught in [didChangeMetrics] below.
  late final FocusNode _searchFocusNode;

  /// Drives the always-visible, draggable scrollbar: 868 tracks are a long
  /// way to swipe. Owned here, created once, disposed once.
  late final ScrollController _scrollController;

  /// The last-played track is restored once, when the library first loads —
  /// never on a manual refresh.
  bool _restoreAttempted = false;

  Future<void> _restoreLastPlayed() async {
    try {
      final songs = await ref.read(songListProvider.future);
      if (!mounted || _restoreAttempted || songs.isEmpty) return;
      _restoreAttempted = true;
      await ref.read(audioPlayerServiceProvider).restoreLastPlayed(songs);
    } catch (_) {
      // No library, no restore: the empty-library UI explains itself.
      _restoreAttempted = true;
    }
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
    _scrollController = ScrollController();
    _tabController = TabController(
      length: LyricsStatus.values.length,
      vsync: this,
      initialIndex: LyricsStatus.values.indexOf(ref.read(libraryTabProvider)),
    );
    // One listener for both routes in: tapping a tab and swiping between them
    // both end up here, so the provider can never disagree with the indicator.
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      ref.read(libraryTabProvider.notifier).state =
          LyricsStatus.values[_tabController.index];
    });
    // Two ways in, because neither alone is enough.
    //
    // The platform tells us directly when a share arrives at a running app —
    // that is the reliable one, and the reason a share into an open Musync used
    // to vanish. The lifecycle observer stays as a backstop for the cold start,
    // where the intent is already waiting before Dart has a listener.
    MediaStore.listenForSharedAudio(() => unawaited(_openSharedAudio()));
    WidgetsBinding.instance.addObserver(this);
    // Re-opens the track that was playing when the app was last closed, once
    // the library has loaded and the track can be found by its path. Paused,
    // at the saved position — never on a manual refresh.
    unawaited(_restoreLastPlayed());

    // The scan needs the audio permission, so ask before anything tries to
    // read MediaStore. Post-frame because a permission dialog cannot be raised
    // while the first frame is still being built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestPermissions());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Cheap when there is nothing waiting: the platform hands back an empty
    // list, and this returns immediately.
    unawaited(_openSharedAudio());
    // The user may have granted the audio permission in the system settings
    // while away: re-check quietly and clear the blocked screen if so, without
    // popping another permission dialog.
    if (ref.read(libraryPermissionDeniedProvider) != null) {
      unawaited(_recheckPermissionOnReturn());
    }
  }

  /// Quiet re-check after a trip to the system settings: if audio access is
  /// granted now, take the same path as a granted startup request.
  Future<void> _recheckPermissionOnReturn() async {
    if (!await PermissionService.hasAudioAccess()) return;
    if (!mounted) return;
    ref.read(libraryPermissionDeniedProvider.notifier).state = null;
    ref.invalidate(songListProvider);
    _restoreAttempted = false;
    unawaited(_restoreLastPlayed());
    await _openSharedAudio();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is ModalRoute<void>) appRouteObserver.subscribe(this, route);
  }

  /// Drops keyboard focus whenever another screen goes on top of this one.
  ///
  /// The search field keeps focus otherwise, for the whole trip to the player
  /// and back — and Flutter raises the keyboard again as soon as the field is
  /// rebuilt, so it reappeared over the library with the user having touched
  /// nothing. The keyboard should only ever come up on a deliberate tap.
  ///
  /// Not tied to the individual `pushNamed` calls: six of them leave this screen
  /// and the seventh someone adds later would bring the bug straight back.
  @override
  void didPushNext() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    MediaStore.stopListeningForSharedAudio();
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // The keyboard went away without the field losing focus (system back
    // button dismisses the keyboard but keeps focus): drop it, otherwise
    // the cursor keeps blinking and the outline stays blue.
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final keyboardHidden =
        views.isEmpty || views.first.viewInsets.bottom == 0;
    if (keyboardHidden && _searchFocusNode.hasFocus) {
      _searchFocusNode.unfocus();
    }
  }

  /// Asks before closing Musync.
  ///
  /// This screen is the root route, so a back gesture here does not go anywhere
  /// — it ends the app. On a phone that gesture is one careless swipe from the
  /// edge, and it is the same swipe used to move between the three tabs, which
  /// makes it easy to trigger by accident.
  ///
  /// Playback itself survives leaving: the audio service keeps going. What is
  /// lost is a scan in progress, a review not yet written, and the place in a
  /// long list — which is enough to be worth one question.
  Future<void> _confirmExit() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.exit_to_app),
        title: const Text('Quitter Musync ?'),
        content: const Text(
          'La lecture en cours continue en arrière-plan. Une recherche par lot '
          'non terminée, elle, sera perdue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Rester'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Quitter'),
          ),
        ],
      ),
    );

    // `SystemNavigator.pop` rather than popping the route: there is nothing
    // underneath this one, and popping the last route leaves a black window
    // instead of returning to the launcher.
    if (leave == true) await SystemNavigator.pop();
  }

  /// Left/right across the list moves between the three tabs.
  ///
  /// `animateTo` rather than setting the index: the underline slides, which is
  /// what tells the user the swipe was understood — an instant jump reads as a
  /// glitch.
  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 120) return;

    // A swipe leftwards moves forward through the tabs, as the content appears
    // to slide out of the way.
    final next = _tabController.index + (velocity < 0 ? 1 : -1);
    if (next < 0 || next >= LyricsStatus.values.length) return;
    _tabController.animateTo(next);
  }

  /// Manual refresh: rescans the library quietly. No snackbar — ignored
  /// files stay visible in the scanner's ignored-files list if needed.
  Future<void> _refreshLibrary() async {
    await ref.read(songListProvider.notifier).refresh();
    // Pull-to-refresh rebuilds the lyrics cache from the files' actual
    // contents: if another app (Musicolet) edited tags, the Sans paroles /
    // Synchronisées tabs and counts are updated, not served stale.
    // The cache is kept for fast startups — this just refreshes it on demand.
    ref.read(lyricsStatusScannerProvider).clear();
    ref.invalidate(lyricsStatusProvider);
    // The current track's lyrics are read straight from disk, bypassing
    // every cache.
    ref.invalidate(currentLyricsProvider);
    // Diagnostic for external edits (Musicolet): log exactly which file
    // Musync reads for the current track, so a path mismatch can be ruled
    // in or out from the Journal (Paramètres, long-press the title).
    unawaited(_logCurrentSongFile());
  }

  /// Logs the current song's file identity to the Journal: path, size,
  /// mtime, raw TIT2, and adjacent .lrc presence.
  Future<void> _logCurrentSongFile() async {
    final song = ref.read(currentSongProvider);
    if (song == null) return;
    final path = song.filePath;
    String size = '?';
    String mtime = '?';
    try {
      final stat = await FileStat.stat(path);
      if (stat.type != FileSystemEntityType.notFound) {
        size = '${stat.size}';
        mtime = stat.modified.toIso8601String();
      } else {
        size = 'NOT FOUND';
      }
    } catch (e) {
      size = 'ERR $e';
    }
    String lrc = 'none';
    final dot = path.lastIndexOf('.');
    if (dot >= 0) {
      for (final ext in ['.lrc', '.LRC']) {
        try {
          if (await File('${path.substring(0, dot)}$ext').exists()) {
            lrc = ext;
            break;
          }
        } catch (_) {}
      }
    }
    String rawTitle = '?';
    try {
      rawTitle = (await Id3Reader.readMetadata(path)).title ?? '(no TIT2)';
    } catch (_) {}
    DebugLog.instance.info(
      'Diag',
      'Morceau en cours: ${song.title}\n'
      'Fichier: $path\n'
      'Taille: $size | Modifié: $mtime | .lrc: $lrc\n'
      'TIT2 brut: $rawTitle',
    );
  }

  Future<void> _requestPermissions() async {
    final outcome = await PermissionService.requestStartupPermissions();
    if (!mounted) return;

    if (outcome == PermissionOutcome.granted) {
      // The provider may have already built and failed against a denied
      // permission; rescanning now is what fills the list.
      ref.invalidate(songListProvider);
      // The startup restore ran against an unreadable library and gave up;
      // now that the permission is granted, try again.
      _restoreAttempted = false;
      unawaited(_restoreLastPlayed());
      // Only now: a share can't be acted on before the library is readable.
      await _openSharedAudio();
      return;
    }

    ref.read(libraryPermissionDeniedProvider.notifier).state = outcome;
  }

  /// Opens whatever was handed to Musync through the share sheet.
  ///
  /// A share means "find the words for this one". A track without synced
  /// lyrics goes straight into the online search, which reads the file name
  /// first (shared tracks are downloads, and their tags are the unreliable
  /// part); one that is already timed opens in the player.
  ///
  /// The guard covers only the *resolving* of the share, never the screen it
  /// leads to. It used to wrap the navigation as well, and `pushNamed` only
  /// completes when the route is popped — so for as long as the player or the
  /// search was open the guard stayed shut, and a second share arriving in that
  /// time was ignored and left waiting in the queue. That was "sharing several
  /// times in a row does nothing".
  bool _handlingShare = false;

  Future<void> _openSharedAudio() async {
    // Startup can reach here twice — once the permission is granted, and again
    // on the first `resumed`. The platform queue drains on the first read, but
    // overlapping runs would still race on the lookup below.
    if (_handlingShare) return;
    // The flag goes up before the first await: two overlapping calls must not
    // both slip through while the permission check is in flight.
    _handlingShare = true;
    try {
      // Never drain the native share queue while the library is unreadable: the
      // first `resumed` fires before the permission grant, and draining now would
      // consume the share only to report "not found" — losing it for good. The
      // post-grant call and later resumes drain normally.
      if (!await PermissionService.hasAudioAccess()) return;

      final songs = await _resolveSharedSongs();
      if (songs.isEmpty || !mounted) return;

      await _routeSharedSongs(songs);
    } catch (e) {
      // Called via unawaited() from lifecycle hooks and listeners: an
      // exception here has nowhere to go, so log it instead of surfacing
      // as an unhandled async error.
      DebugLog.instance.error(
        'Partage',
        'Ouverture du partage impossible',
        error: e,
      );
    } finally {
      _handlingShare = false;
    }
  }

  /// Turns the drained share queue into library tracks.
  Future<List<Song>> _resolveSharedSongs() async {
    final (paths: paths, dropped: dropped) = await MediaStore.takeSharedAudio();
    // URIs that couldn't be resolved to files (e.g. from a third-party app's
    // private storage). Reported here — before the early return — so a share
    // with *only* unreadable files still tells the user, instead of the
    // counter surfacing with the next share.
    if (dropped > 0 && mounted) {
      ScaffoldMessenger.of(context).showOnly(
        SnackBar(
          content: Text(
            '$dropped fichier(s) partagé(s) illisible(s) : '
            'format non pris en charge ou accès refusé.',
          ),
        ),
      );
    }
    if (paths.isEmpty || !mounted) return const [];

    final found = <Song>[];
    final unknown = <String>[];
    for (final path in paths) {
      final song = await _findSong(path);
      if (song != null) {
        found.add(song);
      } else {
        unknown.add(path);
      }
    }

    if (unknown.isNotEmpty) {
      // Shared from outside the indexed library — ask MediaStore to look at
      // the files, then scan once more before giving up on them. Rescans run
      // in parallel batches: sequential with a 5s timeout each, a 500-file
      // share would stall here for tens of minutes with zero feedback.
      for (var i = 0; i < unknown.length; i += 8) {
        final batch = unknown.sublist(
          i,
          (i + 8).clamp(0, unknown.length),
        );
        await Future.wait(batch.map(MediaStore.rescan));
        if (!mounted) return const [];
      }
      await ref.read(songListProvider.notifier).refresh();

      final missing = <String>[];
      for (final path in unknown) {
        final song = await _findSong(path);
        if (song != null) {
          found.add(song);
        } else {
          missing.add(path);
        }
      }

      if (!mounted) return const [];
      if (missing.isNotEmpty) {
        // Show all missing files, not just the first — the user shared them
        // all and deserves to know which ones didn't make it.
        final names = missing
            .map((p) => p.split(Platform.pathSeparator).last)
            .take(3)
            .join(', ');
        final more = missing.length > 3 ? ' (+${missing.length - 3} autres)' : '';
        ScaffoldMessenger.of(context).showOnly(
          SnackBar(
            content: Text(
              '${missing.length} fichier(s) non trouvé(s) dans la bibliothèque : '
              '$names$more',
            ),
          ),
        );
      }
    }

    return found;
  }

  /// Sends the shared tracks where they can be worked on.
  Future<void> _routeSharedSongs(List<Song> songs) async {
    final statuses = await ref
        .read(lyricsStatusScannerProvider)
        .statusOfAll(songs.map((song) => song.filePath));
    if (!mounted) return;

    final needSearch = [
      for (final song in songs)
        if ((statuses[song.filePath] ?? LyricsStatus.none) !=
            LyricsStatus.synced)
          song,
    ];

    // A share arriving while another track's player is open replaces it rather
    // than stacking a second one. Only players are closed: the sync editor may
    // hold edits nobody saved, and popping it would drop them.
    final navigator = Navigator.of(context);
    String? top;
    navigator.popUntil((route) {
      top = route.settings.name;
      return true;
    });
    // A search is running and owns the one shared batch state; starting another
    // now would trample it.
    if (top == AppRoutes.batch) {
      ScaffoldMessenger.of(context).showOnly(
        const SnackBar(
          content: Text(
            'Une recherche est déjà en cours. Repartage ce morceau ensuite.',
          ),
        ),
      );
      return;
    }
    navigator.popUntil((route) => route.settings.name != AppRoutes.player);

    if (needSearch.isEmpty) {
      // The player screen is about to open: hide the floating bubble right
      // now instead of waiting for the route callbacks, so a share never
      // leaves the bubble sitting on top of "Lecture en cours".
      ref.read(playerScreenVisibleProvider.notifier).state = true;
      // All shared tracks already have synced lyrics. If several were shared,
      // queue them up instead of silently dropping all but the first.
      if (songs.length == 1) {
        await Navigator.pushNamed(
          context,
          AppRoutes.player,
          arguments: SongRouteArgs(song: songs.first),
        );
      } else {
        await Navigator.pushNamed(
          context,
          AppRoutes.player,
          arguments: SongRouteArgs(song: songs.first, queue: songs.skip(1).toList()),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showOnly(
            SnackBar(
              content: Text(
                '${songs.length} morceaux partagés : lecture du premier, '
                'les autres sont en file d\u2019attente.',
              ),
            ),
          );
        }
      }
      return;
    }
    await _startBatch(needSearch, filenameFirst: true);
  }

  /// Runs a bulk search over whatever the current tab is showing.
  ///
  /// The visible list, not the whole library: the filters are the selection.
  /// Searching the "Sans paroles" tab fills in what is missing; searching
  /// "Simples" looks for timed versions of lyrics that have none.
  Future<void> _startBatch(
    List<Song>? songs, {
    bool filenameFirst = false,
  }) async {
    if (songs == null || songs.isEmpty) return;

    await Navigator.pushNamed(
      context,
      AppRoutes.batch,
      arguments: BatchRequest(songs, filenameFirst: filenameFirst),
    );
    if (!mounted) return;

    // Anything written moved between tabs, so the counts and the list are both
    // out of date.
    ref.invalidate(lyricsStatusProvider);
  }

  Future<Song?> _findSong(String path) async {
    for (final song in await ref.read(songListProvider.future)) {
      if (song.filePath == path) return song;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final songsAsync = ref.watch(filteredSongsProvider);
    final permissionIssue = ref.watch(libraryPermissionDeniedProvider);
    final hasCurrentSong =
        ref.watch(currentSongProvider.select((s) => s != null));
    final tab = ref.watch(libraryTabProvider);
    // Read from the provider, not from the controller: the provider is what
    // actually drove this rebuild, so the controller could still be a frame
    // behind.
    final query = ref.watch(librarySearchProvider).trim();

    // Tells "this phone has no music" apart from "this tab is empty" — two very
    // different things to say to someone staring at a blank list.
    final libraryIsEmpty =
        ref.watch(songListProvider).valueOrNull?.isEmpty ?? false;

    return PopScope(
      // Never pops on its own: the confirmation decides, and it decides by
      // ending the app rather than by popping a route that has nothing behind
      // it.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
        appBar: permissionIssue != null
            ? null
            : _LibraryAppBar(
                songsAsync: songsAsync,
                searchController: _searchController,
                searchFocusNode: _searchFocusNode,
                tabController: _tabController,
                onBatch: () => _startBatch(songsAsync.valueOrNull),
              ),
        body: permissionIssue != null
            ? _PermissionRequired(
                outcome: permissionIssue,
                onRetry: _requestPermissions,
              )
            : GestureDetector(
                onHorizontalDragEnd: _onHorizontalDragEnd,
                child: RefreshIndicator(
                  onRefresh: _refreshLibrary,
                  child: ScrollbarTheme(
                    data: ScrollbarThemeData(
                      // Musicolet style: grey at rest, coloured while
                      // dragged, a touch thicker than the default.
                      thickness: WidgetStateProperty.all(8),
                      radius: const Radius.circular(4),
                      thumbColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.dragged)) {
                          return Theme.of(context).colorScheme.primary;
                        }
                        return Colors.grey.withValues(alpha: 0.55);
                      }),
                    ),
                    child: Scrollbar(
                      controller: _scrollController,
                      // Always visible and draggable: the fast way through
                      // a thousand-track library.
                      thumbVisibility: true,
                      interactive: true,
                      child: CustomScrollView(
                      controller: _scrollController,
                      slivers: [
                      ...switch (songsAsync) {
                        AsyncData(:final value) when value.isEmpty => [
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: libraryIsEmpty
                                ? const _EmptyLibrary()
                                : _EmptyTab(tab: tab, query: query),
                          ),
                        ],
                        AsyncData(:final value) => [
                          if (query.isNotEmpty && value.isNotEmpty)
                            SliverToBoxAdapter(
                              child: _SearchQueueHeader(
                                songs: value,
                                query: query,
                              ),
                            ),
                          SliverList.builder(
                            itemCount: value.length,
                            itemBuilder: (context, index) => SongTile(
                              song: value[index],
                              // Every row in this list shares the tab's status by
                              // construction; showing it keeps a row readable
                              // once it has been scrolled away from its header.
                              status: tab,
                              onTap: () => Navigator.pushNamed(
                                context,
                                AppRoutes.player,
                                arguments: SongRouteArgs(
                                  song: value[index],
                                  queue: value,
                                  index: index,
                                ),
                              ),
                            ),
                          ),
                        ],
                        AsyncError(:final error) => [
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _ScanFailed(
                              error: error,
                              onRetry: () =>
                                  ref.read(songListProvider.notifier).refresh(),
                            ),
                          ),
                        ],
                        _ => [
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        ],
                      },
                      // Keeps the last song reachable above the mini player.
                      SliverToBoxAdapter(
                        child: SizedBox(height: hasCurrentSong ? 8 : 24),
                      ),
                    ],
                    ),
                  ),
                ),
              ),
            ),
        bottomNavigationBar: const _DockedMiniPlayer(),
      ),
    );
  }
}

/// Slides the mini player in and out instead of making the list jump by 66 px
/// the moment playback starts.
class _DockedMiniPlayer extends ConsumerWidget {
  const _DockedMiniPlayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSong =
        ref.watch(currentSongProvider.select((s) => s != null));

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: hasSong
          ? const SafeArea(child: MiniPlayer())
          : const SizedBox.shrink(),
    );
  }
}

String _sortLabel(LibrarySort sort) => switch (sort) {
  LibrarySort.title => 'Par titre',
  LibrarySort.artist => 'Par artiste',
  LibrarySort.album => 'Par album',
};

class _LibraryAppBar extends ConsumerWidget implements PreferredSizeWidget {
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 124);
  final AsyncValue<List> songsAsync;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;

  /// Owned by the screen, so a tap and a swipe drive the same indicator.
  final TabController tabController;

  final VoidCallback onBatch;

  const _LibraryAppBar({
    required this.songsAsync,
    required this.searchController,
    required this.searchFocusNode,
    required this.tabController,
    required this.onBatch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final counts = ref.watch(lyricsStatusCountsProvider);

    final subtitle = switch (songsAsync) {
      AsyncData(:final value) =>
        '${value.length} morceau${value.length > 1 ? 'x' : ''}',
      AsyncError() => 'Analyse impossible',
      _ => 'Analyse en cours…',
    };

    // A plain AppBar, not a sliver: the header lives outside the scrollable
    // so the scrollbar spans exactly the song list — never the header above
    // it, never the mini player below.
    return AppBar(
      title: const Text('Musync'),
      backgroundColor: scheme.surface,
      actions: [
        Center(
          child: Text(
            subtitle,
            style: textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        // No batch search on the Synchronisées tab: those tracks already
        // have synced lyrics, there is nothing to search for.
        if (ref.watch(libraryTabProvider) != LyricsStatus.synced)
          IconButton(
            icon: const Icon(Icons.playlist_add_check),
            tooltip: 'Chercher les paroles de cet onglet',
            onPressed: songsAsync.valueOrNull?.isEmpty ?? true ? null : onBatch,
          ),
        PopupMenuButton<LibrarySort>(
          icon: const Icon(Icons.sort),
          tooltip: 'Trier',
          // The provider and the sort itself were already written and wired
          // into the list — there had simply never been a way to reach them,
          // so the library was stuck on "par titre" without saying so.
          initialValue: ref.watch(librarySortProvider),
          onSelected: (value) =>
              ref.read(librarySortProvider.notifier).state = value,
          itemBuilder: (context) => [
            for (final sort in LibrarySort.values)
              CheckedPopupMenuItem(
                value: sort,
                checked: sort == ref.read(librarySortProvider),
                child: Text(_sortLabel(sort)),
              ),
          ],
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Paramètres',
          onPressed: () => Navigator.pushNamed(context, AppRoutes.settings),
        ),
      ],
      bottom: PreferredSize(
        // Measured tight at the default text scale: field, padding and tabs
        // come to about 102. The margin is for a larger system font, where a
        // fixed height that fits exactly turns into an overflow stripe.
        preferredSize: const Size.fromHeight(124),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _SearchField(
                controller: searchController,
                focusNode: searchFocusNode,
              ),
            ),
            TabBar(
              // Required, and its absence is not a compile error.
              //
              // A TabBar with neither a controller nor a DefaultTabController
              // ancestor throws while building. In release that renders as
              // Flutter's default ErrorWidget — a plain pale rectangle — so the
              // whole app came up as a white screen that never went away, and
              // nothing downstream of this screen ever mounted: no lifecycle
              // observer to collect a share, no mini player, no transport
              // controls.
              //
              // The DefaultTabController that used to supply one was removed
              // when the screen took ownership of the controller, so that
              // swiping and tapping could drive the same indicator. The wiring
              // never followed.
              controller: tabController,
              // No onTap: the controller's listener already writes the change
              // through, and doing it twice would fight the swipe.
              tabs: [
                for (final status in LyricsStatus.values)
                  Tab(
                    height: 46,
                    child: Text(
                      '${lyricsStatusLabel(status)}  ${counts[status]?.toString() ?? '…'}',
                      style: textTheme.labelLarge,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The live filter, with the clear button the spec asks for.
///
/// Listens to the controller rather than holding its own copy of the text, so
/// the clear button appears and disappears without a StatefulWidget whose
/// lifecycle would have to be managed alongside the controller's.
class _SearchField extends ConsumerWidget {
  final TextEditingController controller;
  final FocusNode focusNode;

  const _SearchField({required this.controller, required this.focusNode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        focusNode: focusNode,
        // A tap anywhere else drops focus: the cursor goes away, the
        // outline leaves its blue focused state, and the keyboard follows.
        onTapOutside: (_) => focusNode.unfocus(),
        textInputAction: TextInputAction.search,
        onChanged: (text) =>
            ref.read(librarySearchProvider.notifier).state = text,
        decoration: InputDecoration(
          hintText: 'Titre ou artiste',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Effacer',
                  onPressed: () {
                    controller.clear();
                    ref.read(librarySearchProvider.notifier).state = '';
                  },
                ),
          filled: true,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// Header shown above search results: result count plus a one-tap way to
/// turn the results into a named queue (e.g. search "Juice WRLD" →
/// "Créer une file" → a "Juice WRLD" queue).
class _SearchQueueHeader extends ConsumerWidget {
  final List<Song> songs;
  final String query;

  const _SearchQueueHeader({required this.songs, required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${songs.length} résultat${songs.length > 1 ? 's' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: () => createQueueFromSongs(
              context,
              ref,
              songs,
              suggestedName: query,
            ),
            icon: const Icon(Icons.playlist_add, size: 18),
            label: const Text('Créer une file'),
          ),
        ],
      ),
    );
  }
}

/// Shown when a tab has nothing in it — which is not the same as the phone
/// having no music, and not the same as a search that matched nothing.
class _EmptyTab extends StatelessWidget {
  final LyricsStatus tab;
  final String query;

  const _EmptyTab({required this.tab, required this.query});

  @override
  Widget build(BuildContext context) {
    if (query.isNotEmpty) {
      return _CenteredMessage(
        icon: Icons.search_off,
        title: 'Aucun résultat',
        message: 'Aucun morceau de cet onglet ne correspond à « $query ».',
      );
    }

    return _CenteredMessage(
      icon: lyricsStatusIcon(tab),
      title: switch (tab) {
        LyricsStatus.none => 'Tout est déjà couvert',
        LyricsStatus.plain => 'Aucune paroles simples',
        LyricsStatus.synced => 'Aucune paroles synchronisées',
      },
      message: switch (tab) {
        LyricsStatus.none =>
          'Chaque morceau de la bibliothèque a déjà au moins des paroles.',
        LyricsStatus.plain =>
          'Les morceaux dont les paroles ne sont pas encore calées '
              'apparaîtront ici.',
        LyricsStatus.synced =>
          'Calez les paroles d\'un morceau et il viendra se ranger ici.',
      },
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return const _CenteredMessage(
      icon: Icons.music_off,
      title: 'Aucun morceau trouvé',
      message:
          'Musync n\'a trouvé aucun fichier audio sur cet appareil. '
          'Tirez vers le bas pour relancer l\'analyse.',
    );
  }
}

class _ScanFailed extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ScanFailed({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return _CenteredMessage(
      icon: Icons.error_outline,
      title: 'Analyse impossible',
      message: '$error',
      action: FilledButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('Réessayer'),
      ),
    );
  }
}

class _PermissionRequired extends StatelessWidget {
  final PermissionOutcome outcome;
  final VoidCallback onRetry;

  const _PermissionRequired({required this.outcome, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isPermanent = outcome == PermissionOutcome.permanentlyDenied;

    return _CenteredMessage(
      icon: Icons.library_music_outlined,
      title: 'Accès à la musique requis',
      message: isPermanent
          ? 'L\'autorisation a été refusée définitivement. Activez-la dans les '
                'paramètres d\'Android pour que Musync puisse lire votre '
                'bibliothèque.'
          : 'Musync a besoin d\'accéder à vos fichiers audio pour afficher '
                'votre bibliothèque.',
      action: FilledButton.icon(
        onPressed: isPermanent ? PermissionService.openSettings : onRetry,
        icon: Icon(isPermanent ? Icons.settings : Icons.check, size: 18),
        label: Text(isPermanent ? 'Ouvrir les paramètres' : 'Autoriser'),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: scheme.onSurfaceVariant),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(color: scheme.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}
