import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/shared_http_client.dart';
import 'package:musync/features/lyrics/data/lyrics_mismatch_store.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/lyrics_source_health.dart';
import 'package:musync/features/lyrics/data/lyrics_word_timings_store.dart';
import 'package:musync/features/lyrics/data/providers/genius_provider.dart';
import 'package:musync/features/lyrics/data/providers/netease_provider.dart';
import 'package:musync/features/lyrics/data/providers/kugou_provider.dart';
import 'package:musync/features/lyrics/data/providers/lrclib_provider.dart';
import 'package:musync/features/lyrics/data/providers/lrcred_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyricsplus_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/settings/data/lyrics_source_config.dart';
import 'package:musync/features/settings/providers/settings_provider.dart';

/// The health of the lyrics sources, shared by every repository the app
/// builds. Top-level (not inside the repository) so it survives the
/// rebuilds that follow a settings change — a cooldown must not reset
/// because the user toggled a source.
final lyricsSourceHealthProvider = Provider<LyricsSourceHealth>(
  (ref) => LyricsSourceHealth(),
);

/// Built from whatever sources the user has switched on (plan P5).
///
/// Rebuilds when the settings change, so adding an instance or toggling one off
/// takes effect on the next search without a restart. Until the list has loaded
/// — a file read, so a frame or two — the bundled LRCLIB stands in, which keeps
/// a search launched immediately on startup working.
final lyricsRepositoryProvider = Provider<LyricsRepository>((ref) {
  final configs = ref.watch(lyricsSourcesProvider).valueOrNull;
  final client = ref.watch(sharedHttpClientProvider);
  final mismatchStore = ref.watch(lyricsMismatchStoreProvider);
  final wordTimingsStore = ref.watch(lyricsWordTimingsStoreProvider);
  final health = ref.watch(lyricsSourceHealthProvider);
  if (configs == null) {
    return LyricsRepository(
      sources: [LrclibSource(client: client)],
      mismatchStore: mismatchStore,
      wordTimingsStore: wordTimingsStore,
      health: health,
    );
  }

  return LyricsRepository(
    mismatchStore: mismatchStore,
    wordTimingsStore: wordTimingsStore,
    health: health,
    sources: [
      for (final config in configs.where((c) => c.enabled))
        switch (config.kind) {
          LyricsSourceKind.lrclib =>
            config.isBuiltIn
                ? LrclibSource(client: client)
                : LrclibSource.custom(
                    name: config.name,
                    baseUrl: config.baseUrl,
                    client: client,
                  ),
          // The bundled entry carries the fixed default URL and name, so
          // passing the config through is the same as the defaults — and
          // a stored non-built-in entry keeps its own values.
          LyricsSourceKind.lyricsPlus => LyricsPlusSource(
            client: client,
            baseUrl: config.baseUrl,
            name: config.name,
          ),
          // Same shape as LyricsPlus: the bundled entry is the only one,
          // with the fixed default URL and name.
          LyricsSourceKind.lrcRed => LrcRedSource(
            client: client,
            baseUrl: config.baseUrl,
            name: config.name,
          ),
          // Same shape again: the bundled entry is the only one, with
          // the fixed default URL and name.
          LyricsSourceKind.kugou => KugouSource(
            client: client,
            baseUrl: config.baseUrl,
            name: config.name,
          ),
          // Same shape again: the bundled entry is the only one, with
          // the fixed default URL and name.
          LyricsSourceKind.genius => GeniusSource(
            client: client,
            baseUrl: config.baseUrl,
            name: config.name,
          ),
          // Same shape again: the bundled entry is the only one, with
          // the fixed default URL and name.
          LyricsSourceKind.netEase => NetEaseSource(
            client: client,
            baseUrl: config.baseUrl,
            name: config.name,
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

/// Set when the user cancels the search in flight. Cleared when a new
/// search starts, so the auto-retry of the *next* search is unaffected.
///
/// The auto-retry (search screen) fires from the cancelled search's own
/// completion: without this, cancelling a search with no results yet would
/// immediately relaunch one with the guessed title/artist — the × would
/// start a search instead of stopping it.
final lyricsSearchCancelledProvider = StateProvider<bool>((ref) => false);

/// Which search is the latest one. Two searches launched in quick succession
/// (a corrected query, a double tap) overlap in flight, and the older one may
/// finish last — without this, its stale results would overwrite the newer
/// ones on screen. Only the latest generation may write to the state.
int _searchGeneration = 0;

/// Runs a lyrics search and puts the outcome in the search state.
///
/// [explicit] is a deliberate re-search (the Rechercher button, Enter):
/// the "no lyrics" memo for this query is dropped first, so the sources
/// are asked again. An automatic search (screen open, auto-retry) leaves
/// the memo alone — reopening a song a minute later must not re-ask a
/// source that already said nothing.
///
/// [sourceName] asks one source only (the "try another source" bypass):
/// a set-aside source is asked anyway, and the outcome feeds the health.
///
/// Returns what was found, so a caller that needs to react (a toast when
/// a single source finds nothing) does not have to re-read the state.
Future<List<LyricsSearchResult>> performLyricsSearch(
  WidgetRef ref, {
  required String title,
  required String artist,
  String? album,
  int? durationMs,
  bool explicit = false,
  String? sourceName,
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
  final cancelled = ref.read(lyricsSearchCancelledProvider.notifier);
  final repository = ref.read(lyricsRepositoryProvider);

  final generation = ++_searchGeneration;
  loading.state = true;
  error.state = null;
  results.state = [];
  cancelled.state = false;

  if (explicit) {
    ref
        .read(lyricsSourceHealthProvider)
        .forgetTrack(lyricsHealthTrackKey(title, artist));
  }

  // A newer search started while this one was in flight: its results are
  // stale, drop them instead of flashing them over the newer ones.
  bool isStale() => generation != _searchGeneration;

  try {
    if (sourceName != null) {
      final found = await repository.searchOne(
        sourceName: sourceName,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
      );
      if (!isStale()) results.state = found;
      return found;
    }
    // Streamed: the first hit shows as soon as its source answers,
    // the list settles ranked once every source has answered. A newer
    // search cancels this one — breaking out of the loop cancels the
    // subscription, and the stream's late emissions go nowhere.
    var found = const <LyricsSearchResult>[];
    await for (final ranked in repository.searchAllStream(
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
    )) {
      if (isStale()) break;
      found = ranked;
      results.state = ranked;
    }
    return found;
  } on LyricsSourceException catch (e) {
    // The source already phrased this for the user; `toString()` would put the
    // class name and the source id in front of it.
    if (!isStale()) error.state = e.message;
    return const [];
  } catch (e, stack) {
    DebugLog.instance.error(
      'Recherche',
      'Échec de la recherche « $title » / « $artist »',
      error: e,
      stackTrace: stack,
    );
    if (!isStale()) error.state = 'Erreur inattendue : $e';
    return const [];
  } finally {
    if (!isStale()) loading.state = false;
  }
}

/// Cancels the search in flight, if any.
///
/// Bumps the generation, so the running [performLyricsSearch] treats its
/// late results as stale and breaks out of the stream on the next emission
/// — the subscription is cancelled and no late emission reaches the
/// screen. The loading flag drops at once instead of waiting for that next
/// emission: a search whose remaining sources all hang would otherwise spin
/// forever. Results already written to state stay: they are valid hits from
/// sources that already answered.
void cancelLyricsSearch(WidgetRef ref) {
  ++_searchGeneration;
  ref.read(lyricsSearchCancelledProvider.notifier).state = true;
  ref.read(lyricsSearchLoadingProvider.notifier).state = false;
}
