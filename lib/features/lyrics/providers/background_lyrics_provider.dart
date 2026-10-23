import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/lyrics/providers/tag_change_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';
import 'package:musync/features/settings/providers/backup_provider.dart';
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
///   online (otherwise it does nothing at all), resolves a trustworthy
///   artist/title (tags first, then the filename heuristic, then the AI
///   reader as a last resort), and asks the lyrics sources for a synced
///   version. The best hit is written straight into the file, synced or
///   plain — no confidence gate, no confirmation dialog, just the usual
///   quiet snackbar (with undo).
/// * The whole library: some time after startup, and only on WiFi, every
///   track that still lacks synced lyrics gets the same treatment, one after
///   another with a breather between searches.
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
    // abandons the search silently.
    unawaited(_maybeFetch(next));
  }

  Future<void> _maybeFetch(Song song) async {
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

    // Local check first: a synced track needs nothing.
    final status = precheck[1] as LyricsStatus?;
    if (status == null || status == LyricsStatus.synced) return;
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
      if (status == LyricsStatus.synced) continue;
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
      if (statuses[song.filePath] == LyricsStatus.synced) continue;
      if (_attempted.contains(song.filePath)) continue;
      _attempted.add(song.filePath);
      // WiFi dropped mid-sweep: stop here, next launch resumes.
      if (!await MediaStore.isWifiConnected()) break;
      if (await _searchAndWrite(song, aiFallback: aiFallback) != null) {
        written++;
      }
      await Future.delayed(_searchGap);
    }

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

  /// Searches for lyrics for [song] and silently writes the best hit.
  ///
  /// Ranked best-first by the repository: the first synced hit wins, no
  /// confidence gate; otherwise the first hit with plain text. When the
  /// tag-based query finds nothing, the AI gets one shot at reading the
  /// file name and the search runs a second time with its guess — never
  /// twice with the same query. Returns whether an undo is available and
  /// whether the written lyrics are synced, or null when nothing was
  /// written. The backup behind the undo is what puts the write in
  /// Settings › Historique.
  Future<({bool canUndo, bool synced})?> _searchAndWrite(
    Song song, {
    bool aiFallback = true,
  }) async {
    // A search is only as good as its query: tags first, then the filename
    // heuristic, then the AI reader as a last resort.
    final query = await _resolveQuery(song, aiFallback: aiFallback);
    if (query == null) return null;

    final repository = _ref.read(lyricsRepositoryProvider);
    List<LyricsSearchResult> results;
    try {
      results = await repository.searchAll(
        title: query.title,
        artist: query.artist,
        durationMs: song.duration,
      );
    } catch (_) {
      // Every source failed: stay silent, try again next session.
      DebugLog.instance.info(
        'Paroles auto',
        'Recherche impossible pour ${song.title}',
      );
      return null;
    }
    var match = _bestMatch(results);
    // The tags led nowhere: one AI guess from the file name, then a second
    // search with it.
    if (match == null && aiFallback && !query.aiUsed) {
      final aiGuess = await _aiGuess(song);
      final aiTitle = aiGuess?.title.trim() ?? '';
      final aiArtist = aiGuess?.artist.trim() ?? '';
      final sameQuery = aiTitle.toLowerCase() == query.title.toLowerCase() &&
          aiArtist.toLowerCase() == query.artist.toLowerCase();
      if (aiTitle.isNotEmpty && aiArtist.isNotEmpty && !sameQuery) {
        DebugLog.instance.info(
          'Paroles auto',
          'Nouvel essai via IA pour ${song.title}',
        );
        try {
          results = await repository.searchAll(
            title: aiTitle,
            artist: aiArtist,
            durationMs: song.duration,
          );
        } catch (_) {
          return null;
        }
        match = _bestMatch(results);
      }
    }
    if (match == null) return null;
    // Idempotent: a repeated sweep must not rewrite identical lyrics and
    // spam the Historique with no-op writes.
    try {
      final current = await Id3Reader.readLyrics(song.filePath);
      final sameSynced = match.hasSyncedLyrics &&
          current.synced != null &&
          current.synced == match.syncedLyrics;
      final samePlain = !match.hasSyncedLyrics &&
          current.unsynced == match.unsyncedLyrics;
      if (sameSynced || samePlain) return null;
    } catch (_) {
      // Unreadable tags: fall through and let the write try.
    }
    // No permission prompt from the background: without write access there is
    // simply no silent write.
    if (!await PermissionService.hasWriteAccess()) return null;

    // Backup, write, record — the same trio the manual embed performs, minus
    // the confirmation UI.
    final backups = _ref.read(tagBackupStoreProvider);
    final changes = _ref.read(tagChangeProvider);
    final canUndo = await backups.capture(song.filePath);
    try {
      await repository.embedLyrics(
        song.filePath,
        synced: match.syncedLyrics,
        unsynced: match.unsyncedLyrics,
      );
    } catch (e, stack) {
      DebugLog.instance.error(
        'Paroles auto',
        "Échec de l'écriture pour ${song.title}",
        error: e,
        stackTrace: stack,
      );
      if (canUndo) await backups.discardLatest(song.filePath);
      return null;
    }
    if (canUndo) await backups.markWritten(song.filePath);
    changes.fileChanged(song.filePath);
    return (canUndo: canUndo, synced: match.hasSyncedLyrics);
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

  /// Best-first: the first synced hit wins, otherwise the first hit with
  /// plain text, when that is all there is.
  LyricsSearchResult? _bestMatch(List<LyricsSearchResult> results) =>
      results.where((r) => r.hasSyncedLyrics).firstOrNull ??
      results.where((r) => r.hasUnsyncedLyrics).firstOrNull;

  /// The artist/title the search runs on.
  ///
  /// The tags first; when they are blank, the same filename heuristic as the
  /// search screen's « Deviner Artiste/Titre » button fills the gaps; when
  /// that still leaves blanks, the configured AI providers get one shot at
  /// reading the file name. Null when nothing yields something searchable:
  /// a blind search is worse than none.
  Future<({String title, String artist, bool aiUsed})?> _resolveQuery(
    Song song, {
    bool aiFallback = true,
  }) async {
    var title = song.title.trim();
    var artist = song.artist.trim();
    var aiUsed = false;
    if (title.isEmpty || artist.isEmpty) {
      final guess = FilenameParser.parse(song.filePath);
      if (title.isEmpty) title = guess.title.trim();
      if (artist.isEmpty) artist = guess.artist.trim();
    }
    if ((title.isEmpty || artist.isEmpty) && aiFallback) {
      final aiGuess = await _aiGuess(song);
      if (aiGuess != null) {
        if (title.isEmpty) title = aiGuess.title.trim();
        if (artist.isEmpty) artist = aiGuess.artist.trim();
        aiUsed = true;
      }
    }
    if (title.isEmpty || artist.isEmpty) return null;
    return (title: title, artist: artist, aiUsed: aiUsed);
  }

  /// One AI shot at reading the artist/title out of the file name.
  /// Null when no provider is configured or none could answer.
  Future<FilenameGuess?> _aiGuess(Song song) async {
    final settings = _ref.read(aiSettingsProvider).valueOrNull;
    if (settings == null || settings.usable.isEmpty) return null;
    final fileName = song.filePath.split(RegExp(r'[/\\]')).last;
    final resolution = await _ref
        .read(aiFilenameResolverProvider)
        .resolve(settings: settings, fileName: fileName);
    return resolution.guess;
  }
}
