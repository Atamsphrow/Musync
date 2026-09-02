/// Named routes for Musync.
///
/// Every route that needs a song takes it through [SongRouteArgs] rather than a
/// loose map, so a missing or mistyped argument is a compile error instead of
/// the "Missing song argument" placeholder screen it used to produce.
library;

import 'package:flutter/material.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/ui/library_screen.dart';
import 'package:musync/features/lyrics/ui/batch_screen.dart';
import 'package:musync/features/settings/ui/settings_screen.dart';
import 'package:musync/features/sync_editor/providers/sync_editor_provider.dart';
import 'package:musync/features/lyrics/ui/lyrics_search_screen.dart';
import 'package:musync/features/player/ui/player_screen.dart';
import 'package:musync/features/sync_editor/ui/sync_editor_screen.dart';

/// Lets a screen know when another one is pushed over it, or uncovered again.
///
/// Registered once on the [MaterialApp]. The library screen uses it to drop
/// keyboard focus on the way out: without that, the search field kept focus for
/// the whole trip to the player and back, and Flutter dutifully raised the
/// keyboard again the moment the field was rebuilt — with the user having
/// touched nothing.
///
/// Handled here rather than at each `pushNamed`, because the fault is not in any
/// one of them. Sprinkling `unfocus()` across the call sites would fix today's
/// six and quietly leave the seventh to reintroduce it.
final appRouteObserver = RouteObserver<ModalRoute<void>>();

class AppRoutes {
  AppRoutes._();

  static const String library = '/';
  static const String player = '/player';
  static const String lyricsSearch = '/lyrics-search';
  static const String syncEditor = '/sync-editor';
  static const String settings = '/settings';
  static const String batch = '/batch';
}

/// Arguments for every song-scoped route.
///
/// [queue] and [index] are only meaningful for the player: opening a track from
/// the library should play the whole list from that point, not just the one
/// song.
@immutable
class SongRouteArgs {
  final Song song;
  final List<Song>? queue;
  final int? index;

  /// Which half of the sync editor to open on, for the two menu entries that
  /// lead there (T4). Null lets the editor choose from what the file holds,
  /// which is the right default when it is reached any other way.
  final SyncMode? editorMode;

  const SongRouteArgs({
    required this.song,
    this.queue,
    this.index,
    this.editorMode,
  });
}

class AppRouter {
  AppRouter._();

  static Route<dynamic> generateRoute(RouteSettings settings) {
    final args = settings.arguments;

    switch (settings.name) {
      case AppRoutes.library:
        return _buildRoute(settings, const LibraryScreen());

      case AppRoutes.settings:
        return _buildRoute(settings, const SettingsScreen());

      case AppRoutes.batch:
        if (args is List<Song>) {
          return _buildRoute(settings, BatchScreen(songs: args));
        }
        return _buildRoute(
          settings,
          const _RouteError('Aucun morceau à traiter.'),
        );

      case AppRoutes.player:
        return _buildRoute(settings, const PlayerScreen());

      case AppRoutes.lyricsSearch:
        if (args is SongRouteArgs) {
          return _buildRoute(settings, LyricsSearchScreen(song: args.song));
        }
        return _buildRoute(
          settings,
          const _RouteError('Aucun morceau fourni.'),
        );

      case AppRoutes.syncEditor:
        if (args is SongRouteArgs) {
          return _buildRoute(
            settings,
            SyncEditorScreen(song: args.song, initialMode: args.editorMode),
          );
        }
        return _buildRoute(
          settings,
          const _RouteError('Aucun morceau fourni.'),
        );

      // An unknown route opens the library rather than a dead end.
      //
      // Belt and braces behind the manifest's `flutter_deeplinking_enabled`.
      // Flutter used to hand this method an incoming intent's data as a route
      // name, so opening a track with Musync from a file manager produced
      // "Page introuvable : /storage/emulated/0/Audio/09. Snapchat.mp3" and a
      // back arrow to nowhere. The manifest stops that at the source; this makes
      // sure no future route name can strand someone on an error page either.
      //
      // The name is still logged, because a route that does not exist is a
      // programming mistake even when it lands somewhere sensible.
      default:
        DebugLog.instance.warning(
          'Navigation',
          'Route inconnue, ouverture de la bibliothèque : ${settings.name}',
        );
        return _buildRoute(settings, const LibraryScreen());
    }
  }

  /// The player slides up from the bottom, the way a now-playing screen is
  /// expected to; everything else uses the platform default.
  static Route<dynamic> _buildRoute(RouteSettings settings, Widget page) {
    if (settings.name != AppRoutes.player) {
      return MaterialPageRoute(settings: settings, builder: (_) => page);
    }

    return PageRouteBuilder(
      settings: settings,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final offset = animation.drive(
          Tween(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)),
        );
        return SlideTransition(position: offset, child: child);
      },
      transitionDuration: const Duration(milliseconds: 350),
      reverseTransitionDuration: const Duration(milliseconds: 300),
    );
  }
}

class _RouteError extends StatelessWidget {
  final String message;

  const _RouteError(this.message);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: scheme.error),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
