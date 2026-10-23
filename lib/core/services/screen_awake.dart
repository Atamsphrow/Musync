import 'package:flutter/services.dart';

/// Keeps the display awake while lyrics are on screen.
///
/// Lyrics are read, not glanced at: a screen that dims mid-chorus —
/// while the now-playing lyrics pane is up, plain or synced — forces
/// a tap every thirty seconds for no benefit. The holders are the
/// player screen's lyrics pane (through this class) and the floating
/// bubble (natively, on its own overlay window — see the vendored
/// overlay plugin).
///
/// Native side: a window flag on the activity (FLAG_KEEP_SCREEN_ON,
/// channel `com.atamsphrow.musync/screen` in MainActivity). No
/// permission, no wakelock, nothing to leak: Android drops the flag
/// with the window. Counted, so overlapping holders compose — the
/// flag follows the count, not any single screen's lifecycle.
class ScreenAwake {
  ScreenAwake._();

  static const MethodChannel _channel = MethodChannel(
    'com.atamsphrow.musync/screen',
  );

  static int _holders = 0;

  /// One more display wants the screen on.
  static Future<void> acquire() async {
    _holders++;
    if (_holders == 1) await _set(true);
  }

  /// One holder lets go. Releasing more than was acquired is a no-op.
  static Future<void> release() async {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) await _set(false);
  }

  static Future<void> _set(bool on) async {
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {'on': on});
    } on MissingPluginException {
      // Not Android (tests, desktop): nothing to keep awake through
      // this channel.
    } on PlatformException {
      // Best effort: a failed flag must never break the screen that
      // asked for it.
    }
  }
}
