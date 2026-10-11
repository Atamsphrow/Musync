import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/lyrics/providers/background_lyrics_provider.dart';
import 'package:workmanager/workmanager.dart';

/// Headless entry point for the periodic lyrics sweep.
///
/// Runs in a background isolate with the app closed: no widgets, no
/// messenger — every UI touch inside the sweep is null-safe on its own, so
/// there is nothing to guard here. Registered once from
/// [BackgroundLyricsService.start].
@pragma('vm:entry-point')
void lyricsSweepDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != BackgroundLyricsService.sweepTaskName) return true;
    final container = ProviderContainer();
    try {
      await container
          .read(backgroundLyricsServiceProvider)
          .runHeadlessSweep();
    } catch (_) {
      // A failed sweep retries at the next window; never crash the worker.
    } finally {
      container.dispose();
    }
    return true;
  });
}
