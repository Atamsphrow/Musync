/// Android permission handling.
///
/// Musync needs three different things, and they are asked for at three
/// different moments on purpose:
///
///  - **Reading the library** (`READ_MEDIA_AUDIO`, or `READ_EXTERNAL_STORAGE`
///    below Android 13) and **notifications** are requested at launch. Without
///    them the app has nothing to show and no playback controls, so there is no
///    point deferring.
///
///  - **Writing tags** is requested the first time the user actually embeds
///    lyrics, not at launch. See [requestWriteAccess] for why that permission
///    is the one it is.
library;

import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart';

/// Outcome of a permission request, kept distinct because the UI has to react
/// differently: a plain refusal can be asked again, a permanent one can only be
/// undone from the system settings.
enum PermissionOutcome {
  granted,
  denied,

  /// Refused for good ("Don't ask again"), or blocked by policy. The only way
  /// forward is [openSettings].
  permanentlyDenied,
}

class PermissionService {
  PermissionService._();

  /// Requests everything needed before the library screen can do its job.
  ///
  /// Notification permission is requested but not required: refusing it costs
  /// the media notification, not playback.
  static Future<PermissionOutcome> requestStartupPermissions() async {
    if (!Platform.isAndroid) return PermissionOutcome.granted;

    final audio = await _requestAudioAccess();
    // Asked second so the audio prompt — the one that gates everything — is
    // the first thing the user sees.
    await Permission.notification.request();
    return audio;
  }

  /// `READ_MEDIA_AUDIO` on Android 13+, `READ_EXTERNAL_STORAGE` before that.
  ///
  /// Both are tried rather than branching on the SDK version, which saves
  /// pulling in a device-info dependency just to read one int. The catch is
  /// that the inapplicable one does not come back "unavailable" — it comes back
  /// *permanently denied*, which the result below has to account for.
  static Future<PermissionOutcome> _requestAudioAccess() async {
    if (await Permission.audio.isGranted ||
        await Permission.storage.isGranted) {
      return PermissionOutcome.granted;
    }

    final audio = await Permission.audio.request();
    if (audio.isGranted) return PermissionOutcome.granted;

    final storage = await Permission.storage.request();
    if (storage.isGranted) return PermissionOutcome.granted;

    // Both must be permanent, not either.
    //
    // Whichever of the two does not apply to the running version comes back
    // *permanently* denied, not merely denied — the platform has no such
    // permission to prompt for. Verified on Android 13, where the manifest caps
    // `READ_EXTERNAL_STORAGE` at `maxSdkVersion="32"`, so `permission_handler`
    // logs "No permissions found in manifest" and reports it permanent.
    //
    // With `||`, that lone absent permission was enough to classify an ordinary
    // "not now" as final, sending the user off to the system settings for a
    // refusal a second prompt would have fixed.
    if (audio.isPermanentlyDenied && storage.isPermanentlyDenied) {
      return PermissionOutcome.permanentlyDenied;
    }
    return PermissionOutcome.denied;
  }

  static Future<bool> hasAudioAccess() async {
    if (!Platform.isAndroid) return true;
    return await Permission.audio.isGranted ||
        await Permission.storage.isGranted;
  }

  // ── Write access ──

  /// Whether Musync can currently write to the user's music files.
  static Future<bool> hasWriteAccess() async {
    if (!Platform.isAndroid) return true;
    // Below Android 11 the plain storage grant already allows writing.
    if (await Permission.manageExternalStorage.isGranted) return true;
    return Permission.storage.isGranted;
  }

  /// Asks for "All files access" (`MANAGE_EXTERNAL_STORAGE`).
  ///
  /// This is the invasive one, and the choice deserves stating. Musync embeds
  /// lyrics *into the user's existing MP3s*, which under scoped storage
  /// (Android 11+) leaves exactly three options:
  ///
  ///  1. `MediaStore.createWriteRequest()` — a system consent dialog per file.
  ///     Correct in spirit, but a tagging app touches dozens of files and there
  ///     is no maintained Flutter binding for it.
  ///  2. The Storage Access Framework — one grant for a whole folder tree, but
  ///     all I/O then has to go through SAF URIs, which `dart:io` cannot open.
  ///     The entire ID3 layer would have to be rewritten against a plugin.
  ///  3. `MANAGE_EXTERNAL_STORAGE` — one grant, and `File` keeps working.
  ///
  /// (3) is what this app uses. It is a deliberate trade: Musync is sideloaded
  /// rather than shipped through Play, where this permission requires a
  /// justification review. If Musync is ever published, option (2) is the way
  /// out, and only `Id3Writer`'s two I/O helpers would need to change.
  ///
  /// Requesting it opens a full-screen system settings page rather than a
  /// dialog, so callers should explain what is about to happen first.
  static Future<PermissionOutcome> requestWriteAccess() async {
    if (!Platform.isAndroid) return PermissionOutcome.granted;
    if (await hasWriteAccess()) return PermissionOutcome.granted;

    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return PermissionOutcome.granted;
    if (status.isPermanentlyDenied) return PermissionOutcome.permanentlyDenied;
    return PermissionOutcome.denied;
  }

  /// Opens the app's page in the system settings — the only way back from
  /// [PermissionOutcome.permanentlyDenied].
  static Future<bool> openSettings() => openAppSettings();
}
