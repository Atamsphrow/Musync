/// Named routes for Musync.
///
/// Every route that needs a song takes it through [SongRouteArgs] rather than a
/// loose map, so a missing or mistyped argument is a compile error instead of
/// the "Missing song argument" placeholder screen it used to produce.
library;

import 'package:flutter/material.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/ui/library_screen.dart';
import 'package:musync/features/lyrics/ui/lyrics_search_screen.dart';
import 'package:musync/features/player/ui/player_screen.dart';
import 'package:musync/features/sync_editor/ui/sync_editor_screen.dart';

class AppRoutes {
  AppRoutes._();

  static const String library = '/';
  static const String player = '/player';
  static const String lyricsSearch = '/lyrics-search';
  static const String syncEditor = '/sync-editor';
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

  const SongRouteArgs({required this.song, this.queue, this.index});
}

class AppRouter {
  AppRouter._();

  static Route<dynamic> generateRoute(RouteSettings settings) {
    final args = settings.arguments;

    switch (settings.name) {
      case AppRoutes.library:
        return _buildRoute(settings, const LibraryScreen());

      case AppRoutes.player:
        return _buildRoute(settings, const PlayerScreen());

      case AppRoutes.lyricsSearch:
        if (args is SongRouteArgs) {
          return _buildRoute(settings, LyricsSearchScreen(song: args.song));
        }
        return _buildRoute(settings, const _RouteError('Aucun morceau fourni.'));

      case AppRoutes.syncEditor:
        if (args is SongRouteArgs) {
          return _buildRoute(settings, SyncEditorScreen(song: args.song));
        }
        return _buildRoute(settings, const _RouteError('Aucun morceau fourni.'));

      default:
        return _buildRoute(
          settings,
          _RouteError('Page introuvable : ${settings.name}'),
        );
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
          Tween(begin: const Offset(0, 1), end: Offset.zero)
              .chain(CurveTween(curve: Curves.easeOutCubic)),
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
