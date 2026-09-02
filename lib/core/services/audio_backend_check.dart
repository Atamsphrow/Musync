/// Whether just_audio_background is actually in the loop.
///
/// This exists because of a bug that survived six releases: audio plays, and no
/// media notification or lock-screen control ever appears. The device settles
/// most of the guesses — POST_NOTIFICATIONS is granted, the AudioService is
/// bound, a MediaSession exists — and leaves exactly one:
///
/// `AudioService` on the Android side posts its notification from
/// `enterPlayingState()`, which runs only on the transition to `playing == true`
/// reported from Dart. Nothing else creates the notification channel, and on the
/// phone no channel existed at all — proof that the transition was never
/// reported.
///
/// What reports it is `just_audio_background`, and it can only do so if it
/// replaced `JustAudioPlatform.instance` *before* the app's `AudioPlayer` was
/// constructed. If it did not, the player talks to the plain platform, plays
/// perfectly, and nothing is ever announced. No exception, no log line, no
/// notification — which is the symptom exactly.
///
/// So the app now checks, instead of assuming.
library;

import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musync/core/services/debug_log.dart';

abstract final class AudioBackendCheck {
  /// The name of whatever is currently answering as the just_audio platform.
  ///
  /// `_JustAudioBackgroundPlugin` means the interception is in place and a
  /// notification is possible. `MethodChannelJustAudio` means it is not, and no
  /// notification can ever appear however well everything else is configured.
  static String get platformName =>
      JustAudioPlatform.instance.runtimeType.toString();

  /// True when the background wrapper is the active platform.
  ///
  /// Matched on the name rather than the type: the class is private to
  /// just_audio_background, so there is nothing to import and compare against.
  /// A name test is weaker than a type test and is worth saying so out loud —
  /// but the alternative is no test at all.
  static bool get isIntercepted => platformName.contains('Background');

  /// Records the answer where both the user and a `logcat` can see it.
  ///
  /// Printed as well as logged, on purpose. `DebugLog` only echoes to the
  /// console in debug builds, and every build that has ever shown this bug was
  /// a release build — so the one line that identifies the cause has to survive
  /// into release logcat.
  static void report(String moment) {
    final line =
        'Plateforme just_audio à $moment : $platformName '
        '(${isIntercepted ? 'interception en place' : 'PAS intercepté — aucune '
                  'notification média ne peut apparaître'})';

    // ignore: avoid_print — has to reach logcat in a release build.
    print('[Musync/Audio] $line');

    if (isIntercepted) {
      DebugLog.instance.info('Audio', line);
    } else {
      DebugLog.instance.error('Audio', line);
    }
  }

  /// The wrapper, remembered from the one moment it is provably installed.
  static JustAudioPlatform? _wrapper;

  /// Remembers it. Called from `main` straight after
  /// `JustAudioBackground.init()`.
  static void capture() {
    if (isIntercepted) _wrapper = JustAudioPlatform.instance;
  }

  /// Puts the wrapper back if something has replaced it since.
  ///
  /// This is the fix for the notification that never appeared, and the reason
  /// the obvious version of the fix did nothing.
  ///
  /// `AudioPlayer()` does **not** resolve `JustAudioPlatform.instance` when it is
  /// constructed — it builds a local idle stub, and creates the real platform
  /// player lazily, on the first `load()` (just_audio.dart:1425). So building
  /// the player early pins nothing. Between startup and that first load, the
  /// Activity attaches to audio_service's cached FlutterEngine and the plugin
  /// registrant runs again, setting this static back to the plain
  /// `MethodChannelJustAudio`.
  ///
  /// just_audio then creates an ordinary platform player. Audio plays perfectly.
  /// Nothing is ever announced: on the device, Musync's MediaSession sat at
  /// `active=false, state=NONE` while a track was playing, the foreground
  /// service was never started, and the notification channel was never even
  /// created — because `audio_service` is only ever told to create it when Dart
  /// reports that playback began.
  ///
  /// Returns true when it had to intervene, so the caller can say so.
  static bool ensureIntercepted() {
    if (isIntercepted) {
      // Reported too, and this matters: silence on the happy path left the log
      // unable to say whether a track had even been started. Once per session,
      // so a hundred plays do not bury everything else.
      DebugLog.instance.once(
        'audio-intercepted-at-load',
        LogLevel.info,
        'Audio',
        'Plateforme just_audio au premier chargement : $platformName '
            '(interception en place)',
      );
      return false;
    }

    final wrapper = _wrapper;
    if (wrapper == null) {
      DebugLog.instance.once(
        'audio-no-wrapper',
        LogLevel.error,
        'Audio',
        'La lecture ne passe pas par le service et rien ne peut le rétablir : '
            'aucune notification média ne peut apparaître.',
      );
      return false;
    }

    JustAudioPlatform.instance = wrapper;
    report('la restauration juste avant le chargement');
    return true;
  }
}
