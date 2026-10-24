import 'dart:async';
import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';
import 'package:musync/core/services/debug_log.dart';

/// TEMPORARY diagnostic (the freeze/lag hunt, October 2026).
///
/// Logs, under the « Perf » tag, the frames that blow the budget or
/// that arrive late. How to read an entry:
///  * build large, raster small → Dart build/layout cost;
///  * raster large, build small → GPU / image / shadow cost;
///  * attente or écart large with build AND raster small → something was
///    busy BETWEEN frames. The heartbeat tells which side:
///      - an « isolate Dart bloqué » entry of the same size → the UI
///        isolate (a microtask, a timer, a stream listener);
///      - no such entry → the Dart isolate was free: the Android main
///        thread (which delivers vsync via Choreographer and runs plugin
///        method-channel handlers) was busy.
///
/// A « sonde active » line opens every observation and a « fin » line
/// closes it with the maxima, so silence in between means « no slow
/// frame », never « no probe ».
class FrameProbe {
  FrameProbe._(this.label, this._maxFrames, this._thresholdMs);

  final String label;
  final int _maxFrames;
  final int _thresholdMs;
  int _seen = 0;
  bool _active = true;
  int? _previousBuildStartUs;
  late final TimingsCallback _callback = _onTimings;

  int _maxBuild = 0;
  int _maxRaster = 0;
  int _maxWait = 0;
  int _maxGap = 0;

  /// Dart-side heartbeat: a timer that should fire every [_beatPeriod].
  /// When it fires late, the UI isolate itself was busy for that long.
  static const Duration _beatPeriod = Duration(milliseconds: 8);

  /// The heartbeat never outlives this, even if no frame ever arrives.
  static const Duration _beatMaxDuration = Duration(seconds: 3);

  final Stopwatch _beatClock = Stopwatch();
  int _lastBeatUs = 0;
  int _maxBeatLate = 0;
  Timer? _heartbeat;

  /// Observes [frames] frames, then stops by itself. For an open-ended
  /// observation (a gesture, a scroll), pass a huge count and [stop]
  /// explicitly. [thresholdMs] is the budget over which an entry is
  /// written. Count frames generously: at 120 Hz, 30 frames is 250 ms.
  static FrameProbe start(
    String label, {
    int frames = 60,
    int thresholdMs = 16,
  }) {
    final probe = FrameProbe._(label, frames, thresholdMs);
    DebugLog.instance.info('Perf', '$label : sonde active');
    SchedulerBinding.instance.addTimingsCallback(probe._callback);
    probe._startHeartbeat();
    return probe;
  }

  void _startHeartbeat() {
    _beatClock.start();
    _heartbeat = Timer.periodic(_beatPeriod, (_) {
      final nowUs = _beatClock.elapsedMicroseconds;
      final lateMs =
          (nowUs - _lastBeatUs) ~/ 1000 - _beatPeriod.inMilliseconds;
      _lastBeatUs = nowUs;
      if (lateMs > _maxBeatLate) _maxBeatLate = lateMs;
      if (lateMs > _thresholdMs * 3) {
        DebugLog.instance.info(
          'Perf',
          '$label isolate Dart bloqué ~${lateMs}ms '
          '(à t=${nowUs ~/ 1000}ms)',
        );
      }
      if (_beatClock.elapsed >= _beatMaxDuration) _stopHeartbeat();
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _beatClock.stop();
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

      if (build > _maxBuild) _maxBuild = build;
      if (raster > _maxRaster) _maxRaster = raster;
      if (wait > _maxWait) _maxWait = wait;
      if (gap > _maxGap) _maxGap = gap;

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
    _stopHeartbeat();
    DebugLog.instance.info(
      'Perf',
      '$label fin : $_seen frames, max build=${_maxBuild}ms '
      'raster=${_maxRaster}ms attente=${_maxWait}ms écart=${_maxGap}ms, '
      'retard max isolate=${_maxBeatLate}ms',
    );
  }
}
