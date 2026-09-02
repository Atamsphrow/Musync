/// Tells Android's media index that a file on disk has changed.
///
/// Musync embeds lyrics by rewriting the track through a temp file and a
/// `rename`. That is atomic — an interrupted write can never leave a half
/// written song — but it gives the path a new inode, and MediaStore goes on
/// serving the row it indexed before. Players that read the library through
/// MediaStore then hold a handle to a file that is gone, which is what made
/// Musicolet fall silent and crash-loop on tracks Musync had just written,
/// while VLC — which walks the filesystem directly — played them fine.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:musync/core/services/debug_log.dart';

/// What came of asking Android to open a track elsewhere.
enum ShareOutcome {
  /// Handed over. Whether the other app does anything useful with it is its
  /// business.
  opened,

  /// The app that was asked for is not on this phone.
  appNotInstalled,

  /// Anything else — no channel, a timeout, a URI Android declined.
  failed,
}

abstract final class MediaStore {
  static const MethodChannel _channel = MethodChannel(
    'com.atamsphrow.musync/media_store',
  );

  /// How long to wait for the scanner. `scanFile` does not promise to call back
  /// for a path it cannot read, so the future has to be bounded or a failed
  /// scan would hang the save.
  static const Duration _timeout = Duration(seconds: 5);

  /// Re-indexes [filePath], returning whether the scan actually completed.
  ///
  /// Never throws. A stale index is a far smaller problem than a save that
  /// reports failure over lyrics already written to disk, so every failure mode
  /// — no platform channel, a scanner that never answers, a path MediaStore
  /// declines — comes back as false and leaves the caller's write standing.
  static Future<bool> rescan(String filePath) async {
    if (!Platform.isAndroid) return true;

    try {
      await _channel
          .invokeMethod<String>('rescan', <String, String>{'path': filePath})
          .timeout(_timeout);
      return true;
    } on TimeoutException {
      // Every branch here means the same thing to the user: the file was
      // rewritten correctly and MediaStore was not told, so another player may
      // keep pointing at the inode that is gone. That is the P0 symptom exactly,
      // and it needs to be visible when it recurs — the save itself still
      // reports success, because the lyrics really are on disk.
      _reportRescanFailure(filePath, 'le scanner n\'a pas répondu à temps');
      return false;
    } on MissingPluginException {
      // Nothing registered the channel — unit tests, or a stale engine.
      _reportRescanFailure(filePath, 'canal de plateforme absent');
      return false;
    } on PlatformException catch (e) {
      _reportRescanFailure(filePath, e.message ?? e.code);
      return false;
    }
  }

  static void _reportRescanFailure(String filePath, String why) {
    DebugLog.instance.warning(
      'MediaStore',
      'Réindexation refusée pour $filePath ($why) : un autre lecteur peut '
          'continuer à voir l\'ancienne version du fichier',
    );
  }

  /// Collects audio handed to Musync through the share sheet or "open with",
  /// and empties the platform-side queue.
  ///
  /// Paths only. A stream Android cannot expose as a real file never reaches
  /// here: Musync rewrites tags in place, so a copy in the cache would produce
  /// a tagged duplicate nobody asked for, and saying so is better than
  /// pretending it worked.
  ///
  /// Draining is the point — a share is a one-shot event, and re-serving it
  /// would reopen the same track on every resume.
  /// Opens the system share sheet for a track, by its MediaStore id.
  ///
  /// The point is checking one's own work: write lyrics here, send the track
  /// straight to Musicolet, and see whether they show up timed — without going
  /// out through a file manager to find it again.
  ///
  /// Names the outcome, because the three are worth telling apart.
  static Future<ShareOutcome> shareAudio({
    required int mediaStoreId,
    String? title,

    /// Skip the chooser and hand the track straight to this app.
    ///
    /// See [musicoletPackage] for why this exists.
    String? targetPackage,
  }) async {
    if (!Platform.isAndroid) return ShareOutcome.failed;

    try {
      final ok = await _channel
          .invokeMethod<bool>('shareAudio', <String, Object?>{
            'mediaStoreId': mediaStoreId,
            'title': title,
            'targetPackage': ?targetPackage,
          })
          .timeout(_timeout);
      return (ok ?? false) ? ShareOutcome.opened : ShareOutcome.failed;
    } on TimeoutException {
      return ShareOutcome.failed;
    } on MissingPluginException {
      return ShareOutcome.failed;
    } on PlatformException catch (e) {
      // The one failure the user can do something about.
      return e.code == 'not_installed'
          ? ShareOutcome.appNotInstalled
          : ShareOutcome.failed;
    }
  }

  /// Musicolet's application id.
  ///
  /// Hard-coded on purpose. Musync's whole reason for existing is that Musicolet
  /// reads `[mm:ss.xx]` prefixes out of the plain lyrics frame, and the loop the
  /// app is built around is: write the timings here, then look at them there.
  /// A chooser in the middle of that loop is pure friction, and Musicolet does
  /// not appear in a *share* sheet anyway — a music player declares a handler
  /// for opening audio, not for receiving a share.
  static const String musicoletPackage = 'in.krosbits.musicolet';

  /// Registers [onArrived] for shares that land while Musync is already open.
  ///
  /// Pushed from the platform rather than polled from here. The first version
  /// waited for the app-lifecycle callback and then asked — but that callback
  /// does not reliably fire when the activity was already in the foreground, so
  /// a share into a running Musync went into the queue and stayed there.
  ///
  /// Only one listener at a time, which is the truth of it: there is one queue
  /// and one screen that knows what to do with it.
  static void listenForSharedAudio(void Function() onArrived) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedAudioArrived') onArrived();
    });
  }

  static void stopListeningForSharedAudio() {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler(null);
  }

  static Future<List<String>> takeSharedAudio() async {
    if (!Platform.isAndroid) return const <String>[];

    try {
      final paths = await _channel
          .invokeListMethod<String>('takeSharedAudio')
          .timeout(_timeout);
      return paths ?? const <String>[];
    } on TimeoutException {
      return const <String>[];
    } on MissingPluginException {
      return const <String>[];
    } on PlatformException {
      return const <String>[];
    }
  }
}
