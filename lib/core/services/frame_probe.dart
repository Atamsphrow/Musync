import 'package:flutter/scheduler.dart';
import 'package:musync/core/services/debug_log.dart';

/// TEMPORARY diagnostic (the freeze/lag hunt, October 2026): logs the
/// slow frames (tag « Perf ») while it is active, so a device session
/// says which screens cost build time and which cost raster time
/// instead of feeding another round of guessing. Logs only frames over
/// the 16 ms budget. Remove with its call sites once the hunt is over.
class FrameProbe {
  FrameProbe._(this.label, this._maxFrames);

  final String label;
  final int _maxFrames;
  int _seen = 0;
  bool _active = true;
  late final TimingsCallback _callback = _onTimings;

  /// Observes [frames] frames, then stops by itself. For an open-ended
  /// observation (a gesture, a scroll), pass a huge count and [stop]
  /// explicitly.
  static FrameProbe start(String label, {int frames = 60}) {
    final probe = FrameProbe._(label, frames);
    SchedulerBinding.instance.addTimingsCallback(probe._callback);
    return probe;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      if (!_active) return;
      _seen++;
      final build = t.buildDuration.inMilliseconds;
      final raster = t.rasterDuration.inMilliseconds;
      if (build > 16 || raster > 16) {
        DebugLog.instance.info(
          'Perf',
          '$label frame $_seen : build=${build}ms raster=${raster}ms',
        );
      }
      if (_seen >= _maxFrames) {
        stop();
        return;
      }
    }
  }

  void stop() {
    if (!_active) return;
    _active = false;
    SchedulerBinding.instance.removeTimingsCallback(_callback);
  }
}
