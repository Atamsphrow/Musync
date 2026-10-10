import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
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

/// Fetches synced lyrics in the background for whatever is playing.
///
/// When a track with no lyrics — or plain, untimed lyrics — has been playing
/// for a while, the lyrics sources are asked for a synced version. If the
/// best hit is confident enough it is written straight into the file: no
/// confirmation dialog, just the usual quiet snackbar (with undo).
///
/// The write goes through the tag backup store, so it shows up in
/// Settings › Historique like any other write, and can be undone from there.
class BackgroundLyricsService {
  final Ref _ref;

  /// Tracks already checked this session, so a replay doesn't search again.
  final Set<String> _attempted = {};

  Timer? _timer;
  bool _started = false;

  /// How long a track must be playing before a search goes out. Skipping
  /// through tracks must not spray the API.
  static const _settleDelay = Duration(seconds: 20);

  /// Same bar as the batch screen's auto-select: below it, a human picks.
  /// A silent write only happens above it.
  static const _minConfidence = 0.8;

  BackgroundLyricsService(this._ref);

  void start() {
    if (_started) return;
    _started = true;
    _ref.listen<Song?>(currentSongProvider, (previous, next) {
      _onSongChanged(previous, next);
    });
    _onSongChanged(null, _ref.read(currentSongProvider));
  }

  void _onSongChanged(Song? previous, Song? next) {
    _timer?.cancel();
    if (next == null) return;
    if (previous?.filePath == next.filePath) return;
    if (_attempted.contains(next.filePath)) return;
    _timer = Timer(_settleDelay, () => _maybeFetch(next));
  }

  Future<void> _maybeFetch(Song song) async {
    // The user moved on while the timer ran.
    if (_ref.read(currentSongProvider)?.filePath != song.filePath) return;
    // Only for something actually being listened to.
    final playing = _ref.read(playerStateProvider).valueOrNull?.playing ?? false;
    if (!playing) return;
    _attempted.add(song.filePath);

    // Local check first: a synced track needs nothing.
    final LyricsStatus status;
    try {
      status = await _ref.read(lyricsStatusScannerProvider).statusOf(song.filePath);
    } catch (_) {
      return;
    }
    if (status == LyricsStatus.synced) return;
    if (_ref.read(currentSongProvider)?.filePath != song.filePath) return;

    final repository = _ref.read(lyricsRepositoryProvider);
    final List<LyricsSearchResult> results;
    try {
      results = await repository.searchAll(
        title: song.title,
        artist: song.artist,
        durationMs: song.duration,
      );
    } catch (_) {
      // Offline, or every source failed: stay silent, try again next session.
      DebugLog.instance.info(
        'Paroles auto',
        'Recherche impossible pour ${song.title}',
      );
      return;
    }
    // Ranked best-first by the repository: the first confident synced hit.
    final match = results
        .where((r) => r.hasSyncedLyrics && r.confidence >= _minConfidence)
        .firstOrNull;
    if (match == null) return;
    if (_ref.read(currentSongProvider)?.filePath != song.filePath) return;
    // No permission prompt from the background: without write access there is
    // simply no silent write.
    if (!await PermissionService.hasWriteAccess()) return;

    // Backup, write, record — the same trio the manual embed performs, minus
    // the confirmation UI. The backup is what puts this write in the history.
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
      return;
    }
    if (canUndo) await backups.markWritten(song.filePath);
    changes.fileChanged(song.filePath);

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

  Future<void> _undo(String filePath) async {
    final message = await _ref.read(tagChangeProvider).undo(filePath);
    if (message != null) {
      appMessengerKey.currentState?.showOnly(SnackBar(content: Text(message)));
    }
  }
}
