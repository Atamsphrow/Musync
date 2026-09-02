import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'core/router/app_router.dart';
import 'core/services/audio_backend_check.dart';
import 'core/services/debug_log.dart';
import 'core/utils/snackbar.dart';
import 'core/services/error_capture.dart';
import 'core/theme/app_theme.dart';
import 'features/player/data/audio_player_service.dart';
import 'features/player/providers/player_provider.dart';

/// Wrapped so that nothing thrown during startup goes unrecorded.
///
/// `PlatformDispatcher.instance.onError` covers uncaught errors once the app is
/// up. It does not cover `main` itself, and startup is where the failures with
/// no UI to report them live — a plugin that will not initialise leaves a blank
/// screen and an empty log, which is the position this app was in twice.
void main() => runGuarded(_start);

Future<void> _start() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Before anything else that can fail. Musync is sideloaded onto a phone that
  // is rarely attached to a laptop, so an exception that only reaches logcat
  // reaches nobody; this routes them into the Settings > Journal panel, where
  // the user can copy a report out.
  DebugLog.install();

  // A crash on the Android side takes the process down before Dart hears about
  // it, so the previous run's is read back from disk here — the only place it
  // can be. Not awaited: it is a file read, and nothing below depends on it.
  unawaited(NativeCrashReport.collect());

  // A build failure has to say what it was.
  //
  // Flutter's default ErrorWidget is the red screen in debug — and in release a
  // plain pale rectangle with no text at all. That is how a single missing
  // TabController became "the app opens white and stays white": the exception
  // was raised, caught by the framework, and rendered as a blank box on the one
  // build anybody actually installs.
  //
  // FlutterError.onError above already writes it to the debug log. This puts it
  // on screen too, because an app that will not start is an app whose log
  // cannot be reached.
  ErrorWidget.builder = (details) => _BuildFailure(details: details);

  // Must run before any AudioPlayer is constructed: this installs the
  // background handler behind the media notification, the lock-screen controls
  // and playback once the app leaves the foreground.
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.atamsphrow.musync.playback',
      androidNotificationChannelName: 'Lecture Musync',
      // A dedicated silhouette. The default is `mipmap/ic_launcher`, which here
      // is an adaptive icon — a layered XML — and Android cannot draw one as a
      // notification's small icon: it keeps only the alpha channel. That is why
      // no media notification appeared at all.
      androidNotificationIcon: 'drawable/ic_notification',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    );
    DebugLog.instance.info('Audio', 'Service de lecture en arrière-plan prêt');
    // Init returning is not the same as init having worked.
    //
    // The whole notification chain hangs on one fact: has
    // just_audio_background replaced the just_audio platform? If it has not,
    // playback is perfect and nothing is ever announced to the Android service,
    // so no notification can exist — silently. This says which it is.
    AudioBackendCheck.report('la fin de init');
    // Remembered here, because this is the only moment it is provably
    // the wrapper — and it has to be put back later, see
    // AudioBackendCheck.ensureIntercepted.
    AudioBackendCheck.capture();
  } catch (error, stack) {
    // Not fatal: the library still plays, it just loses the notification and
    // the lock-screen controls. Crashing here would cost the user the whole app
    // over a feature they can live without for one session — but it has to be
    // recorded, because a silent loss is exactly what made this hard to see.
    DebugLog.instance.error(
      'Audio',
      'Le service de lecture en arrière-plan n\'a pas démarré : pas de '
          'notification ni de contrôles sur l\'écran verrouillé',
      error: error,
      stackTrace: stack,
    );
  }

  // The player is built HERE, not on first use.
  //
  // This is the fix for the notification that never appeared. `AudioPlayer`
  // resolves `JustAudioPlatform.instance` when it is constructed and then holds
  // the platform player it was given. Built lazily from the widget tree, it was
  // constructed long after startup — and by then the Activity attaching to
  // audio_service's cached FlutterEngine has re-run the plugin registrant,
  // which sets `JustAudioPlatform.instance` back to the plain
  // `MethodChannelJustAudio`. The player then talked straight to just_audio,
  // played flawlessly, and never told audio_service anything. No notification,
  // no error, nothing in any log.
  //
  // Constructed here it is pinned to the wrapper while the wrapper is
  // demonstrably installed, and nothing that happens to that static afterwards
  // can unwrap it.
  final audioService = AudioPlayerService();
  AudioBackendCheck.report('la construction du lecteur');

  // A banner left over from before the app was backgrounded reads as stuck: its
  // countdown does not run while the engine is paused.
  WidgetsBinding.instance.addObserver(SnackBarLifecycle());

  // Draw behind the system bars; their icon brightness comes from the theme
  // (see AppTheme.fromScheme).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(
    ProviderScope(
      overrides: [
        // The pre-built player, so the provider hands out the pinned one rather
        // than making its own later.
        audioPlayerServiceProvider.overrideWith((ref) {
          ref.onDispose(() => unawaited(audioService.dispose()));
          return audioService;
        }),
      ],
      // A provider that throws does not crash anything — it settles into an
      // error state and the screen renders the exception as text. Which is the
      // right behaviour, and exactly why none of it ever reached the Journal:
      // nothing was uncaught, so nothing was reported. A failed library scan or
      // an unreadable settings file was a line of text on screen and nowhere
      // else.
      observers: const [LoggingProviderObserver()],
      child: const MusyncApp(),
    ),
  );
}

class MusyncApp extends StatelessWidget {
  const MusyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        // darkDynamic is the wallpaper palette on Android 12+, null elsewhere;
        // resolveScheme falls back to the brand seed in that case.
        final scheme = AppTheme.resolveScheme(
          dynamicScheme: darkDynamic,
          brightness: Brightness.dark,
        );
        final theme = AppTheme.fromScheme(scheme);

        return MaterialApp(
          title: 'Musync',
          debugShowCheckedModeBanner: false,
          // Dark only, per the spec. Both slots get the same theme so the app
          // can't be flipped light by the system setting — `themeMode` alone
          // would still let a light theme through if one were ever supplied.
          theme: theme,
          darkTheme: theme,
          themeMode: ThemeMode.dark,
          initialRoute: AppRoutes.library,
          onGenerateRoute: AppRouter.generateRoute,
          navigatorObservers: [appRouteObserver],
          scaffoldMessengerKey: appMessengerKey,
        );
      },
    );
  }
}

/// Shown in place of a widget that threw while building.
///
/// Deliberately built from the lowest-level widgets available. This stands in
/// for something that has just failed, possibly above the MaterialApp, so it
/// cannot assume a Directionality, a Theme, or a Scaffold exists — reaching for
/// any of them would replace one blank screen with another.
class _BuildFailure extends StatelessWidget {
  final FlutterErrorDetails details;

  const _BuildFailure({required this.details});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: const Color(0xFF1E222A),
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Musync n’a pas pu afficher cet écran',
                style: TextStyle(
                  color: Color(0xFFFFB4AB),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              // Selectable, so the text can be copied out and sent on. The
              // debug panel is unreachable when the failure is at startup.
              SelectableText(
                details.exceptionAsString(),
                style: const TextStyle(
                  color: Color(0xFFE3E3E6),
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
