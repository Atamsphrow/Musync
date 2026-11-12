import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/lyrics/data/ai_lyrics_finder.dart';
import 'package:musync/features/lyrics/data/lyrics_mismatch_store.dart';
import 'package:musync/features/lyrics/data/lyrics_provenance.dart';
import 'package:musync/features/lyrics/data/sweep_memory.dart';
import 'package:musync/features/lyrics/providers/tag_change_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:workmanager/workmanager.dart';

/// App-scoped service. Started once from the root widget's `initState`,
/// alongside the automation runner.
final backgroundLyricsServiceProvider = Provider<BackgroundLyricsService>(
  (ref) => BackgroundLyricsService(ref),
);

/// Fetches synced lyrics in the background, two ways.
///
/// * The playing track: when a track with no lyrics — or plain, untimed
///   lyrics — starts playing, the service first checks the device is actually
///   online (otherwise it does nothing at all) and hands the track to the
///   shared [AiLyricsFinder]: identity resolution, search, confidence score,
///   integration only at or above 0.80. A synced track whose provenance says
///   « written by the app below 0.80 » (or nothing at all) is re-verified
///   rather than skipped: a wrong synced lyric used to be « done » forever.
///   A write shows the usual quiet snackbar (with undo).
/// * The whole library: some time after startup, and only on WiFi, every
///   track that still lacks settled synced lyrics gets the same treatment,
///   one after another with a breather between searches.
///
/// Every write goes through the tag backup store, so it shows up in
/// Settings › Historique like any other write, and can be undone from there.
class BackgroundLyricsService {
  final Ref _ref;

  /// WorkManager task name for the headless sweep. Shared with the
  /// dispatcher in `lyrics_sweep_worker.dart`.
  static const sweepTaskName = 'musyncLyricsSweep';

  /// Tracks already checked this session, so a replay — or the sweep meeting
  /// the playing track — doesn't search twice.
  final Set<String> _attempted = {};

  /// Prefetches in flight, by track path. A track change while its
  /// prefetch is still running must join that search instead of starting
  /// a second one for the same track.
  final Map<String, Future<void>> _prefetchFutures = {};

  /// Confirmed « nothing exists for this track » answers, remembered
  /// across launches (see [SweepMemory]) so a launch's sweep does not
  /// re-ask the network — and the AI — about them every single time.
  final SweepMemory _sweepMemory = SweepMemory();

  bool _started = false;

  /// Politeness gap between two searches: LRCLIB is a free service, and a
  /// library-wide sweep must not hammer it.
  static const _searchGap = Duration(seconds: 2);

  BackgroundLyricsService(this._ref);

  void start() {
    if (_started) return;
    _started = true;
    _ref.listen<Song?>(currentSongProvider, (previous, next) {
      _onSongChanged(previous, next);
    });
    _onSongChanged(null, _ref.read(currentSongProvider));
    // The whole-library sweep, once per launch, WiFi only. It used to
    // start the moment the library was ready — which is also the moment
    // the status scan walks every file and the first screens build, so
    // its network calls and tag writes competed with the user's first
    // navigation. It now waits out the launch: 45 s changes nothing for
    // a once-per-launch sweep and leaves the opening seconds alone.
    unawaited(() async {
      await Future<void>.delayed(const Duration(seconds: 45));
      await _sweepLibrary();
    }());
    // ... and once a day with the app closed: WiFi, battery not low.
    unawaited(_registerBackgroundSweep());
  }

  /// Daily headless sweep (WorkManager): the library stays complete even when
  /// the app is never opened. Android only; a failure here never affects the
  /// in-app sweep.
  Future<void> _registerBackgroundSweep() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().registerPeriodicTask(
        'musync-lyrics-sweep',
        sweepTaskName,
        frequency: const Duration(hours: 24),
        constraints: Constraints(
          networkType: NetworkType.unmetered,
          requiresBatteryNotLow: true,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (_) {
      // Plugin unavailable — the in-app sweep still runs.
    }
  }

  /// Entry point for the WorkManager background task (app closed).
  ///
  /// The same sweep as at startup, minus the AI fallback: no API-quota burn
  /// while the user sleeps. Every UI touch inside is null-safe on its own.
  Future<void> runHeadlessSweep() => _sweepLibrary(aiFallback: false);

  void _onSongChanged(Song? previous, Song? next) {
    if (next == null) return;
    if (previous?.filePath == next.filePath) return;
    // No debounce: the check starts with the track. The fetch re-verifies
    // the track is still current after every async gap, so a quick skip just
    // abandons the search silently. The next track's lyrics are prefetched
    // after the current track's search, never alongside it — the prefetch
    // must not cut the search for the song actually playing short.
    unawaited(_maybeFetch(next).then((_) => _prefetchNext()));
  }

  /// Prefetches the next track's lyrics, so they are already there when it
  /// starts. Wi-Fi only, like the sweep, and silent: no snackbar, and a
  /// track the prefetch could not help is left for the normal fetch when it
  /// plays (only a track the prefetch wrote is marked attempted).
  Future<void> _prefetchNext() async {
    if (!await MediaStore.isWifiConnected()) return;
    final service = _ref.read(audioPlayerServiceProvider);
    final next = service.nextSong;
    if (next == null) return;
    // Repeat-one: the next track is the one playing, already fetched.
    if (_ref.read(currentSongProvider)?.filePath == next.filePath) return;
    if (_attempted.contains(next.filePath)) return;
    if (_prefetchFutures.containsKey(next.filePath)) return;
    // Searched at a previous launch and confirmed absent: believed for a
    // fortnight (see SweepMemory) instead of re-queried.
    if (await _sweepMemory.recentlyMissed(
      next.filePath,
      title: next.title,
      artist: next.artist,
    )) {
      return;
    }
    if (await _ref.read(lyricsMismatchStoreProvider).isMismatched(
      next.filePath,
      title: next.title,
      artist: next.artist,
    )) {
      return;
    }
    // Already settled synced lyrics: nothing to fetch.
    final status = await _ref
        .read(lyricsStatusScannerProvider)
        .statusOf(next.filePath)
        .then<LyricsStatus?>((s) => s)
        .catchError((_) => null);
    if (status == LyricsStatus.synced &&
        await _syncedIsSettled(next.filePath)) {
      return;
    }
    final future = _searchAndWrite(next);
    _prefetchFutures[next.filePath] = future;
    try {
      final written = await future;
      // Written: the track is settled, no re-search when it plays.
      if (written != null) _attempted.add(next.filePath);
    } finally {
      _prefetchFutures.remove(next.filePath);
    }
  }

  Future<void> _maybeFetch(Song song) async {
    // A prefetch for this track is still running: join it instead of
    // searching twice, then re-read the status — the prefetch may just
    // have written the lyrics.
    final pendingPrefetch = _prefetchFutures[song.filePath];
    if (pendingPrefetch != null) await pendingPrefetch;
    // The connectivity probe and the local status read run together: neither
    // waits for the other, so the pre-check costs a single round trip.
    final onlineFuture = _hasInternet();
    final statusFuture = _ref
        .read(lyricsStatusScannerProvider)
        .statusOf(song.filePath)
        .then<LyricsStatus?>((s) => s)
        .catchError((_) => null);
    final precheck = await Future.wait([onlineFuture, statusFuture]);
    // First of all: offline, the service does nothing.
    if (precheck[0] != true) return;
    // The user moved on while the check ran.
    if (_ref.read(currentSongProvider)?.filePath != song.filePath) return;
    // Only for something actually being listened to.
    final playing =
        _ref.read(playerStateProvider).valueOrNull?.playing ?? false;
    if (!playing) return;
    if (_attempted.contains(song.filePath)) return;
    _attempted.add(song.filePath);

    // Local check first: a track with no lyrics needs a search. A synced
    // track needs one too when its lyrics are unproven — written by the
    // app below 0.80, or before provenance existed. Only a settled
    // synced track (user lyrics, or auto at 0.80+) is left alone.
    final status = precheck[1] as LyricsStatus?;
    if (status == null) return;
    if (status == LyricsStatus.synced &&
        await _syncedIsSettled(song.filePath)) {
      return;
    }
    if (_ref.read(currentSongProvider)?.filePath != song.filePath) return;

    final written = await _searchAndWrite(song);
    if (written == null) return;
    if (_ref.read(currentSongProvider)?.filePath != song.filePath) return;

    appMessengerKey.currentState?.showOnly(
      SnackBar(
        content: Text(
          written.synced
              ? 'Paroles synchronisées ajoutées.'
              : 'Paroles ajoutées (non synchronisées).',
        ),
        duration: const Duration(seconds: 6),
        action: written.canUndo
            ? SnackBarAction(
                label: 'Annuler',
                onPressed: () => _undo(song.filePath),
              )
            : null,
      ),
    );
  }

  /// Lyrics for explicitly shared tracks, fetched silently in the background.
  ///
  /// A multi-share used to open the batch screen; now the searches run without
  /// showing anything: sequential, with a breather between them — on any
  /// connection, because the share is explicit user intent (unlike the
  /// WiFi-only library sweep). Each write lands in Settings › Historique
  /// with its undo, like any other background write.
  /// A share is explicit intent, so the per-session attempt guard does not
  /// apply — but the tracks are marked attempted, so the per-track fetch does
  /// not search them a second time (and does not show its snackbar either).
  Future<void> fetchForShared(List<Song> songs) async {
    if (songs.isEmpty) return;
    if (!await _hasInternet()) {
      DebugLog.instance.info(
        'Paroles auto',
        'Partage : hors ligne, les recherches attendront le balayage.',
      );
      return;
    }
    for (final song in songs) {
      if (!await _hasInternet()) break;
      // Re-read the status: the file may have gained synced lyrics since the
      // share was routed (an edit, or the per-track fetch winning the race).
      final status = await _ref
          .read(lyricsStatusScannerProvider)
          .statusOf(song.filePath)
          .then<LyricsStatus?>((s) => s)
          .catchError((_) => null);
      if (status == LyricsStatus.synced &&
          await _syncedIsSettled(song.filePath)) {
        continue;
      }
      _attempted.add(song.filePath);
      await _searchAndWrite(song);
      await Future.delayed(_searchGap);
    }
  }

  /// One pass over every track that still lacks synced lyrics.
  ///
  /// WiFi only, sequential, with a breather between searches. Stops early if
  /// WiFi drops; next launch resumes where it left off, since synced tracks
  /// are skipped by status.
  Future<void> _sweepLibrary({bool aiFallback = true}) async {
    if (!await MediaStore.isWifiConnected()) return;
    DebugLog.instance.info('Paroles auto', 'Balayage bibliothèque (WiFi)');

    final List<Song> songs;
    final Map<String, LyricsStatus> statuses;
    try {
      songs = await _ref.read(songListProvider.future);
      statuses = await _ref.read(lyricsStatusProvider.future);
    } catch (_) {
      return;
    }

    var written = 0;
    for (final song in songs) {
      if (statuses[song.filePath] == LyricsStatus.synced &&
          await _syncedIsSettled(song.filePath)) {
        continue;
      }
      if (_attempted.contains(song.filePath)) continue;
      // Searched at a previous launch and confirmed absent: believed
      // for a fortnight (see SweepMemory) instead of re-queried — unless
      // the track was retagged since, in which case the old answer is
      // about a different identity.
      if (await _sweepMemory.recentlyMissed(
        song.filePath,
        title: song.title,
        artist: song.artist,
      )) {
        continue;
      }
      // Marqué « non correspondant » : plus de téléchargement
      // automatique pour ce morceau — comme un raté confirmé, mais
      // sans expiration. Le finder le sauterait aussi ; ce test évite
      // la tentative et l'attente entre deux recherches.
      if (await _ref.read(lyricsMismatchStoreProvider).isMismatched(
        song.filePath,
        title: song.title,
        artist: song.artist,
      )) {
        continue;
      }
      _attempted.add(song.filePath);
      // WiFi dropped mid-sweep: stop here, next launch resumes.
      if (!await MediaStore.isWifiConnected()) break;
      var confirmedMiss = false;
      final outcome = await _searchAndWrite(
        song,
        aiFallback: aiFallback,
        onConfirmedMiss: () => confirmedMiss = true,
      );
      if (outcome != null) {
        written++;
      } else if (confirmedMiss) {
        await _sweepMemory.markMissed(
          song.filePath,
          title: song.title,
          artist: song.artist,
        );
      }
      await Future.delayed(_searchGap);
    }
    await _sweepMemory.save();

    DebugLog.instance.info(
      'Paroles auto',
      'Balayage terminé : $written ajoutée(s)',
    );
    if (written > 0) {
      appMessengerKey.currentState?.showOnly(
        SnackBar(content: Text('$written paroles ajoutées.')),
      );
    }
  }

  /// Searches for lyrics for [song] and silently writes the best hit —
  /// through the shared [AiLyricsFinder], so the background writes
  /// nothing below the 0.80 bar, never overwrites user lyrics alone,
  /// and always goes through backup + Historique + provenance.
  ///
  /// Returns whether an undo is available and whether the written
  /// lyrics are synced, or null when nothing was written. The backup
  /// behind the undo is what puts the write in Settings › Historique.
  /// [onConfirmedMiss] fires only on a confirmed absence: searches ran
  /// on a good-quality query and found nothing — never on a network
  /// failure or an unresolvable query.
  Future<({bool canUndo, bool synced})?> _searchAndWrite(
    Song song, {
    bool aiFallback = true,
    void Function()? onConfirmedMiss,
  }) async {
    final result = await _ref.read(aiLyricsFinderProvider).findFor(
      song,
      aiFallback: aiFallback,
      origin: LyricsProvenanceOrigin.autoBackground,
    );
    if (result.verdict == LyricsFindVerdict.notFound &&
        result.queryGoodQuality &&
        !result.searchesFailed) {
      onConfirmedMiss?.call();
    }
    if (result.verdict != LyricsFindVerdict.integrated) return null;
    // The finder only writes when the backup succeeded, so an undo is
    // always available for a write it made.
    return (canUndo: true, synced: result.best?.hasSyncedLyrics ?? false);
  }

  /// Vrai quand un morceau synchronisé peut être sauté : ses paroles
  /// sont soit protégées (utilisateur), soit écrites par l'app à haute
  /// confiance. Sans provenance, ou à basse confiance, le balayage
  /// revérifie au lieu de sauter.
  Future<bool> _syncedIsSettled(String filePath) async {
    final provenance = await _ref
        .read(lyricsProvenanceStoreProvider)
        .forPath(filePath);
    if (provenance == null) return false;
    if (provenance.isUserOrigin) return true;
    return !provenance.isLowConfidenceAuto;
  }


  Future<void> _undo(String filePath) async {
    final message = await _ref.read(tagChangeProvider).undo(filePath);
    if (message != null) {
      appMessengerKey.currentState?.showOnly(SnackBar(content: Text(message)));
    }
  }

  /// True when the lyrics API host resolves: the device is really online.
  ///
  /// No new dependency for this: resolving the host we are about to call is
  /// the most honest connectivity check there is.
  Future<bool> _hasInternet() async {
    try {
      final addresses = await InternetAddress.lookup(
        'lrclib.net',
      ).timeout(const Duration(seconds: 5));
      return addresses.isNotEmpty;
    } on SocketException catch (_) {
      return false;
    } on TimeoutException catch (_) {
      return false;
    }
  }

}
