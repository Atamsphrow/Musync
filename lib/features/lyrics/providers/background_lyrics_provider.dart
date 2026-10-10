import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:musync/features/settings/providers/backup_provider.dart';

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
///   artist/title (tags first, then the same filename heuristic as the search
///   screen's « Deviner Artiste/Titre » when the tags are blank), and asks
///   the lyrics sources for a synced version. A confident hit is written
///   straight into the file: no confirmation dialog, just the usual quiet
///   snackbar (with undo).
/// * The whole library: some time after startup, and only on WiFi, every
///   track that still lacks synced lyrics gets the same treatment, one after
///   another with a breather between searches.
///
/// Every write goes through the tag backup store, so it shows up in
/// Settings › Historique like any other write, and can be undone from there.
class BackgroundLyricsService {
  final Ref _ref;

  /// Tracks already checked this session, so a replay — or the sweep meeting
  /// the playing track — doesn't search twice.
  final Set<String> _attempted = {};

  bool _started = false;

  /// Same bar as the batch screen's auto-select: below it, a human picks.
  /// A silent write only happens above it.
  static const _minConfidence = 0.8;

  /// Delay after startup before the library sweep begins: the startup scan
  /// gets the disk to itself first.
  static const _sweepDelay = Duration(seconds: 60);

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
    // The whole-library sweep, once per launch, WiFi only.
    Timer(_sweepDelay, () => unawaited(_sweepLibrary()));
  }

  void _onSongChanged(Song? previous, Song? next) {
    if (next == null) return;
    if (previous?.filePath == next.filePath) return;
    // No debounce: the check starts with the track. The fetch re-verifies
    // the track is still current after every async gap, so a quick skip just
    // abandons the search silently.
    unawaited(_maybeFetch(next));
  }

  Future<void> _maybeFetch(Song song) async {
    // First of all: offline, the service does nothing.
    if (!await _hasInternet()) return;
    // The user moved on while the check ran.
    if (_ref.read(currentSongProvider)?.filePath != song.filePath) return;
    // Only for something actually being listened to.
    final playing =
        _ref.read(playerStateProvider).valueOrNull?.playing ?? false;
    if (!playing) return;
    if (_attempted.contains(song.filePath)) return;
    _attempted.add(song.filePath);

    // Local check first: a synced track needs nothing.
    final LyricsStatus status;
    try {
      status = await _ref
          .read(lyricsStatusScannerProvider)
          .statusOf(song.filePath);
    } catch (_) {
      return;
    }
    if (status == LyricsStatus.synced) return;
    if (_ref.read(currentSongProvider)?.filePath != song.filePath) return;

    final canUndo = await _searchAndWrite(song);
    if (canUndo == null) return;
    if (_ref.read(currentSongProvider)?.filePath != song.filePath) return;

    appMessengerKey.currentState?.showOnly(
      SnackBar(
        content: const Text('Paroles synchronisées ajoutées.'),
        duration: const Duration(seconds: 6),
        action: canUndo
            ? SnackBarAction(
                label: 'Annuler',
                onPressed: () => _undo(song.filePath),
              )
            : null,
      ),
    );
  }

  /// One pass over every track that still lacks synced lyrics.
  ///
  /// WiFi only, sequential, with a breather between searches. Stops early if
  /// WiFi drops; next launch resumes where it left off, since synced tracks
  /// are skipped by status.
  Future<void> _sweepLibrary() async {
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
      if (await _searchAndWrite(song) != null) written++;
      await Future.delayed(_searchGap);
    }

    DebugLog.instance.info(
      'Paroles auto',
      'Balayage terminé : $written ajoutée(s)',
    );
    if (written > 0) {
      appMessengerKey.currentState?.showOnly(
        SnackBar(content: Text('$written paroles synchronisées ajoutées.')),
      );
    }
  }

  /// Searches for synced lyrics for [song] and silently writes the best
  /// confident hit.
  ///
  /// Returns whether an undo is available when lyrics were written, or null
  /// when nothing was written. The backup behind the undo is what puts the
  /// write in Settings › Historique.
  Future<bool?> _searchAndWrite(Song song) async {
    // A search is only as good as its query: blank tags get the Deviner
    // heuristic before anything goes out.
    final query = _resolveQuery(song);
    if (query == null) return null;

    final repository = _ref.read(lyricsRepositoryProvider);
    final List<LyricsSearchResult> results;
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
    // Ranked best-first by the repository: the first confident synced hit.
    final match = results
        .where((r) => r.hasSyncedLyrics && r.confidence >= _minConfidence)
        .firstOrNull;
    if (match == null) return null;
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
    return canUndo;
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

  /// The artist/title the search runs on.
  ///
  /// The tags first; when they are blank, the same filename heuristic as the
  /// search screen's « Deviner Artiste/Titre » button fills the gaps. Null
  /// when neither yields something searchable: a blind search is worse than
  /// none, and the confidence gate would reject its results anyway.
  ({String title, String artist})? _resolveQuery(Song song) {
    var title = song.title.trim();
    var artist = song.artist.trim();
    if (title.isEmpty || artist.isEmpty) {
      final guess = FilenameParser.parse(song.filePath);
      if (title.isEmpty) title = guess.title.trim();
      if (artist.isEmpty) artist = guess.artist.trim();
    }
    if (title.isEmpty || artist.isEmpty) return null;
    return (title: title, artist: artist);
  }
}
