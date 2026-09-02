/// Showing a message without building a queue behind it.
library;

import 'package:flutter/material.dart';

extension SnackBarQueue on ScaffoldMessengerState {
  /// Shows [snackBar], replacing anything already on screen or waiting.
  ///
  /// `showSnackBar` queues. Two calls close together — and this app makes them
  /// constantly, between a guess, a save and a rescan — play one after the
  /// other, so the user sits through a chain of banners about a thing they
  /// already did. Worse, only the last one's action is reachable, because the
  /// earlier ones vanish before they can be pressed.
  ///
  /// Only the most recent message is ever true anyway: it describes the state
  /// the app is in now. The ones behind it describe the past.
  void showOnly(SnackBar snackBar) {
    clearSnackBars();
    showSnackBar(snackBar);
  }
}

/// The app's one messenger, reachable without a `BuildContext`.
///
/// Needed so a snackbar can be dismissed from the lifecycle observer below,
/// which has no widget of its own.
final GlobalKey<ScaffoldMessengerState> appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Clears the banner on the way out of the app.
///
/// Flutter counts a snackbar's life with an ordinary `Timer`, and timers do not
/// run while the engine is paused. So a message shown a second before the user
/// switched away still had most of its time left on returning — and the longer
/// ones, the eight-second undo above all, read as stuck: they sat there until
/// swiped, long after the thing they described.
///
/// A message about something that just happened is stale the moment you leave.
/// Dismissing it is not losing information — the undo also lives in
/// Paramètres › Historique, and the failures are all in the Journal.
class SnackBarLifecycle extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `paused` and `hidden` only. `inactive` fires for the notification shade
    // and for a permission dialog, neither of which means the user has left.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      appMessengerKey.currentState?.clearSnackBars();
    }
  }
}
