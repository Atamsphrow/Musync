/// Why the media notification is or is not there.
///
/// T25 has been open across four releases with nothing to go on: the service is
/// initialised in `main`, `JustAudioBackground.init` does not throw, the
/// manifest declares the service and the receiver, and the small icon is a
/// proper single-path silhouette — all verified. Yet no notification appears.
///
/// The remaining candidates are all *runtime* facts that no amount of reading
/// the code can settle, and one of them is silent by design: the notification
/// permission is requested once at launch and its answer is thrown away. Refuse
/// it — or have an OEM refuse it for you — and playback works perfectly while
/// the notification simply never exists. Nothing fails, nothing is logged.
///
/// So the app is made to say what it knows, in the tab where someone would look.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/audio_backend_check.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:permission_handler/permission_handler.dart';

/// One thing that has to be true for the notification to appear.
class AudioCheck {
  final String label;

  /// Null when it could not be determined.
  final bool? ok;

  /// What to do about it, when there is something to do.
  final String? advice;

  const AudioCheck({required this.label, this.ok, this.advice});
}

final audioDiagnosticProvider = FutureProvider<List<AudioCheck>>((ref) async {
  final checks = <AudioCheck>[];

  // 1. Did the background service start? Recorded by `main` either way, so the
  //    log is the only witness — and reading it here saves the user scrolling.
  final audioLines = DebugLog.instance.entries
      .where((e) => e.source == 'Audio')
      .toList();
  final started = audioLines.isEmpty
      ? null
      : audioLines.first.level != LogLevel.error;
  checks.add(
    AudioCheck(
      label: 'Service de lecture en arrière-plan',
      ok: started,
      advice: started == false
          ? 'Il n\'a pas démarré. Le détail est dans le Journal, ligne [Audio].'
          : started == null
          ? 'Rien dans le journal : lancez une lecture, puis revenez ici.'
          : null,
    ),
  );

  // 2. Is just_audio_background actually in the loop?
  //
  //    The one that mattered. audio_service posts its notification only on the
  //    transition to playing==true reported from Dart, and only the background
  //    wrapper reports it. Without the wrapper the player talks straight to
  //    just_audio: perfect playback, nothing announced, no notification, no
  //    error anywhere.
  checks.add(
    AudioCheck(
      label: 'Interception de la lecture',
      ok: AudioBackendCheck.isIntercepted,
      advice: AudioBackendCheck.isIntercepted
          ? null
          : 'La lecture ne passe pas par le service : aucune notification ne '
                'peut apparaître. (${AudioBackendCheck.platformName})',
    ),
  );

  // 3. The notification permission.
  //
  //    This is the candidate nobody thinks of, and the only one that fails in
  //    total silence: the request is made once at launch and its answer is
  //    dropped. Denied, playback still works and the notification never comes.
  final notifications = await Permission.notification.status;
  checks.add(
    AudioCheck(
      label: 'Autorisation des notifications',
      ok: notifications.isGranted,
      advice: notifications.isGranted
          ? null
          : notifications.isPermanentlyDenied
          ? 'Refusée définitivement. Elle ne peut être rendue que depuis les '
                'paramètres Android de Musync.'
          : 'Refusée. Sans elle, Android n\'affichera aucune notification de '
                'lecture, quoi que fasse l\'app.',
    ),
  );

  return checks;
});
