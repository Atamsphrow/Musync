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

import 'package:flutter/foundation.dart';
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
  /// into release logcat. The `print` runs in release only: in debug,
  /// `DebugLog.add` already echoes the same line, and printing it too wrote
  /// it twice in the console.
  static void report(String moment) {
    final line =
        'Plateforme just_audio à $moment : $platformName '
        '(${isIntercepted ? 'interception en place' : 'PAS intercepté — aucune '
                  'notification média ne peut apparaître'})';

    if (!kDebugMode) {
      // ignore: avoid_print — has to reach logcat in a release build.
      print('[Musync/Audio] $line');
    }

    if (isIntercepted) {
      DebugLog.instance.info('Audio', line);
    } else {
      DebugLog.instance.error('Audio', line);
    }
  }

  /// The wrapper, remembered from the one moment it is provably installed.
  static JustAudioPlatform? _wrapper;

  /// Remembers it. Called from `main` straight after
  /// `JustAudioBackground.init()` — and re-called whenever the interception
  /// is observed in place ([ensureIntercepted]): a single capture goes stale
  /// if the platform instance is replaced afterwards, and a stale capture
  /// restores nothing.
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
  /// Returns what happened, so the caller can tell "already fine" apart
  /// from "could not be fixed": [AudioBackendRestore.alreadyIntercepted]
  /// when the interception was already in place,
  /// [AudioBackendRestore.restored] when the wrapper was put back and
  /// verified, [AudioBackendRestore.noWrapper] when nothing was ever
  /// captured, [AudioBackendRestore.restoreFailed] when the restore did
  /// not take. Callers that only care whether the interception is in place
  /// now can read [isIntercepted] afterwards.
  static AudioBackendRestore ensureIntercepted() {
    if (isIntercepted) {
      // Recapture: the platform is provably the wrapper right now, so this
      // refreshes a capture that a later platform swap would have staled.
      capture();
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
      return AudioBackendRestore.alreadyIntercepted;
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
      return AudioBackendRestore.noWrapper;
    }

    JustAudioPlatform.instance = wrapper;
    if (!isIntercepted) {
      // The assignment did not take — a player that already resolved the
      // platform before this ran keeps its own reference, so restoring
      // the static changes nothing for it. Reporting success here would
      // log "interception en place" for a player that will never
      // announce anything.
      DebugLog.instance.error(
        'Audio',
        'La restauration de la plateforme just_audio n\'a pas pris '
            'effet : la lecture ne passe toujours pas par le service.',
      );
      return AudioBackendRestore.restoreFailed;
    }
    report('la restauration juste avant le chargement');
    return AudioBackendRestore.restored;
  }
}

/// What [AudioBackendCheck.ensureIntercepted] found — and did.
///
/// The old boolean collapsed two opposite outcomes into one `false`:
/// "already intercepted, nothing to do" and "no wrapper to restore,
/// unfixable".
enum AudioBackendRestore {
  /// The wrapper was already the active platform; nothing had to be done.
  alreadyIntercepted,

  /// The wrapper was put back and verified in place.
  restored,

  /// No wrapper was ever captured, so there is nothing to put back.
  noWrapper,

  /// The wrapper was put back but the platform still does not report the
  /// interception — the restore did not take.
  restoreFailed,
}
