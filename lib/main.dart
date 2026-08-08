import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Must run before any AudioPlayer is constructed: this installs the
  // background handler behind the media notification, the lock-screen controls
  // and playback once the app leaves the foreground.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.atamsphrow.musync.playback',
    androidNotificationChannelName: 'Lecture Musync',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
  );

  // Draw behind the system bars; their icon brightness comes from the theme
  // (see AppTheme.fromScheme).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(const ProviderScope(child: MusyncApp()));
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
        );
      },
    );
  }
}
