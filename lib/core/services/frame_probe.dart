import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';
import 'package:musync/core/services/debug_log.dart';

/// TEMPORARY diagnostic (the freeze/lag hunt, October 2026).
///
/// Logs, under the « Perf » tag, the frames that blow the budget or
/// that arrive late. How to read an entry:
///  * build large, raster small → Dart build/layout cost;
///  * raster large, build small → GPU / image / shadow cost;
///  * attente or écart large with build AND raster small → the UI
///    isolate (a microtask, a timer, a platform call) or the Android
///    main thread was busy BETWEEN frames — the signature of work like
///    building a 2 870-source queue off the frame path.
class FrameProbe {
  FrameProbe._(this.label, this._maxFrames, this._thresholdMs);

  final String label;
  final int _maxFrames;
  final int _thresholdMs;
  int _seen = 0;
  bool _active = true;
  int? _previousBuildStartUs;
  late final TimingsCallback _callback = _onTimings;

  /// Observes [frames] frames, then stops by itself. For an open-ended
  /// observation (a gesture, a scroll), pass a huge count and [stop]
  /// explicitly. [thresholdMs] is the budget over which an entry is
  /// written.
  static FrameProbe start(
    String label, {
    int frames = 60,
    int thresholdMs = 16,
  }) {
    final probe = FrameProbe._(label, frames, thresholdMs);
    SchedulerBinding.instance.addTimingsCallback(probe._callback);
    return probe;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      if (!_active) return;
      _seen++;
      final build = t.buildDuration.inMilliseconds;
      final raster = t.rasterDuration.inMilliseconds;
      final wait = t.vsyncOverhead.inMilliseconds;
      final buildStartUs = t.timestampInMicroseconds(FramePhase.buildStart);
      final previous = _previousBuildStartUs;
      _previousBuildStartUs = buildStartUs;
      final gap = previous == null ? 0 : (buildStartUs - previous) ~/ 1000;

      if (build > _thresholdMs ||
          raster > _thresholdMs ||
          wait > _thresholdMs ||
          gap > _thresholdMs * 3) {
        DebugLog.instance.info(
          'Perf',
          '$label frame $_seen : build=${build}ms raster=${raster}ms '
          'attente=${wait}ms écart=${gap}ms',
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
