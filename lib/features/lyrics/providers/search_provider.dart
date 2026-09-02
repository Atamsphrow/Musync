import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lrclib_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_ovh_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/settings/data/lyrics_source_config.dart';
import 'package:musync/features/settings/providers/settings_provider.dart';

/// Built from whatever sources the user has switched on (plan P5).
///
/// Rebuilds when the settings change, so adding an instance or toggling one off
/// takes effect on the next search without a restart. Until the list has loaded
/// — a file read, so a frame or two — the bundled LRCLIB stands in, which keeps
/// a search launched immediately on startup working.
final lyricsRepositoryProvider = Provider<LyricsRepository>((ref) {
  final configs = ref.watch(lyricsSourcesProvider).valueOrNull;
  if (configs == null) return LyricsRepository();

  return LyricsRepository(
    sources: [
      for (final config in configs.where((c) => c.enabled))
        switch (config.kind) {
          LyricsSourceKind.lyricsOvh => LyricsOvhSource(),
          LyricsSourceKind.lrclib =>
            config.isBuiltIn
                ? LrclibSource()
                : LrclibSource.custom(
                    name: config.name,
                    baseUrl: config.baseUrl,
                  ),
        },
    ],
  );
});

final lyricsSearchResultsProvider = StateProvider<List<LyricsSearchResult>>(
  (ref) => [],
);
final lyricsSearchLoadingProvider = StateProvider<bool>((ref) => false);
final lyricsSearchErrorProvider = StateProvider<String?>((ref) => null);

Future<void> performLyricsSearch(
  WidgetRef ref, {
  required String title,
  required String artist,
  String? album,
  int? durationMs,
}) async {
  // Everything is resolved off `ref` before the first await, and held.
  //
  // A WidgetRef belongs to the widget that owns it. Leaving the search screen
  // while a request is still in flight — which is exactly what someone does
  // when a source is slow — disposes that widget, and every later `ref.read`
  // throws "Cannot use ref after the widget was disposed". It surfaced as an
  // unhandled exception rather than a failed search, so the screen was already
  // gone and the user saw nothing at all.
  //
  // The controllers outlive the widget: these providers are top-level and
  // never auto-disposed, so writing to them after the fact is safe and the
  // search still finishes into state the next screen can read.
  final loading = ref.read(lyricsSearchLoadingProvider.notifier);
  final error = ref.read(lyricsSearchErrorProvider.notifier);
  final results = ref.read(lyricsSearchResultsProvider.notifier);
  final repository = ref.read(lyricsRepositoryProvider);

  loading.state = true;
  error.state = null;
  results.state = [];

  try {
    results.state = await repository.searchAll(
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
    );
  } on LyricsSourceException catch (e) {
    // The source already phrased this for the user; `toString()` would put the
    // class name and the source id in front of it.
    error.state = e.message;
  } catch (e, stack) {
    DebugLog.instance.error(
      'Recherche',
      'Échec de la recherche « $title » / « $artist »',
      error: e,
      stackTrace: stack,
    );
    error.state = 'Erreur inattendue : $e';
  } finally {
    loading.state = false;
  }
}
