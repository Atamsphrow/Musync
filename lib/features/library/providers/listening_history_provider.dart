/// The listening history: recorded as tracks play, read by « Historique ».
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart'
    show PositionDiscontinuity, PositionDiscontinuityReason;
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/listening_history_store.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';

final listeningHistoryStoreProvider = Provider<ListeningHistoryStore>(
  (ref) => const ListeningHistoryStore(),
);

final listeningHistoryProvider =
    NotifierProvider<ListeningHistoryNotifier, Map<String, ListenEntry>>(
      ListeningHistoryNotifier.new,
    );

class ListeningHistoryNotifier extends Notifier<Map<String, ListenEntry>> {
  bool _loaded = false;
  final List<(String, int)> _beforeLoad = [];

  /// The load in flight, which [movePath] waits for.
  Future<void> _hydration = Future.value();

  @override
  Map<String, ListenEntry> build() {
    // The notifier outlives a rebuild (an import invalidates it): until the
    // file is read again, listens wait in [_beforeLoad] — saved now, the
    // empty state would overwrite the history just imported.
    _loaded = false;
    _hydration = _hydrate();
    return const {};
  }

  Future<void> _hydrate() async {
    final loaded = Map<String, ListenEntry>.of(
      await ref.read(listeningHistoryStoreProvider).load(),
    );
    // Listens recorded while the file was still loading are replayed on top.
    final hadPending = _beforeLoad.isNotEmpty;
    for (final (path, atMs) in _beforeLoad) {
      loaded[path] =
          (loaded[path] ?? ListenEntry(count: 0, lastPlayedMs: atMs))
              .counted(atMs);
    }
    _beforeLoad.clear();
    _loaded = true;
    state = Map.unmodifiable(loaded);
    if (hadPending) await _save();
  }

  /// Counts one listen of [path] at [atMs].
  Future<void> record(String path, {int? atMs}) async {
    final at = atMs ?? DateTime.now().millisecondsSinceEpoch;
    if (!_loaded) {
      _beforeLoad.add((path, at));
      return;
    }
    final next = Map<String, ListenEntry>.of(state);
    next[path] =
        (next[path] ?? ListenEntry(count: 0, lastPlayedMs: at)).counted(at);
    state = Map.unmodifiable(next);
    await _save();
  }

  /// The app renamed or moved a file: its listens follow it. Added to the
  /// new path's own, if it already had some.
  Future<void> movePath(String oldPath, String newPath) async {
    await _hydration;
    final moved = state[oldPath];
    if (oldPath == newPath || moved == null) return;
    final next = Map<String, ListenEntry>.of(state)..remove(oldPath);
    final there = next[newPath];
    next[newPath] = there == null
        ? moved
        : ListenEntry(
            count: there.count + moved.count,
            lastPlayedMs: there.lastPlayedMs > moved.lastPlayedMs
                ? there.lastPlayedMs
                : moved.lastPlayedMs,
          );
    state = Map.unmodifiable(next);
    await _save();
  }

  /// Forgets everything (« Effacer l'historique »).
  Future<void> clear() async {
    _beforeLoad.clear();
    state = const {};
    await _save();
  }

  Future<void> _save() async {
    try {
      await ref.read(listeningHistoryStoreProvider).save(state);
    } catch (error, stack) {
      DebugLog.instance.error(
        'Historique',
        'Enregistrement de l’historique impossible',
        error: error,
        stackTrace: stack,
      );
    }
  }
}

/// Counts listens as tracks play: once per time a track starts — becomes
/// current, or starts over (repeat-one, replayed, a one-track loop) — and
/// plays past [listenThreshold]. Started once by the app root.
final listeningHistoryRecorderProvider = Provider<ListeningHistoryRecorder>((
  ref,
) {
  final recorder = ListeningHistoryRecorder(
    ref.watch(audioPlayerServiceProvider),
    (path) => ref.read(listeningHistoryProvider.notifier).record(path),
  );
  ref.onDispose(recorder.stop);
  return recorder;
});

class ListeningHistoryRecorder {
  ListeningHistoryRecorder(this._service, this._record);

  final AudioPlayerService _service;
  final Future<void> Function(String path) _record;

  StreamSubscription<Song?>? _songSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PositionDiscontinuity>? _discontinuitySub;
  Song? _tracking;
  bool _counted = false;

  /// Back within this much of the start after the listen was counted: the
  /// same track is playing again, from the top — the next pass is a new
  /// listen. Catches what emits no new track: a one-track queue on repeat
  /// all, a replay of the playing track, « Précédent » restarting it.
  static const Duration restartWindow = Duration(seconds: 3);

  void start() {
    if (_songSub != null) return;
    _tracking = _service.currentSong;
    _songSub = _service.currentSongStream.listen((song) {
      final sameTrack = song?.id == _tracking?.id;
      // Always the latest copy, even for the same track: a rename or a move
      // re-emits it with its new path, and the listen must land there.
      _tracking = song;
      if (!sameTrack) _counted = false;
    });
    // Rides the position stream the service already feeds; no timer of its
    // own.
    _positionSub = _service.positionStream.listen(_onPosition);
    // Repeat-one wraps the track without changing it: just_audio reports
    // that as an auto-advance onto the same index.
    _discontinuitySub = _service.positionDiscontinuityStream.listen((event) {
      if (event.reason != PositionDiscontinuityReason.autoAdvance) return;
      if (event.previousEvent.currentIndex == event.event.currentIndex) {
        _counted = false;
      }
    });
  }

  void _onPosition(Duration position) {
    final song = _tracking;
    if (song == null) return;
    final threshold = listenThreshold(song.durationValue);
    if (_counted) {
      // Never at or past the threshold itself (a very short track's is
      // below the window): that would count the same pass twice.
      final window = threshold < restartWindow * 2
          ? threshold ~/ 2
          : restartWindow;
      if (position < window) _counted = false;
      return;
    }
    if (!_service.isPlaying) return;
    if (position < threshold) return;
    _counted = true;
    unawaited(_record(song.filePath));
  }

  void stop() {
    unawaited(_songSub?.cancel());
    unawaited(_positionSub?.cancel());
    unawaited(_discontinuitySub?.cancel());
    _songSub = null;
    _positionSub = null;
    _discontinuitySub = null;
  }
}

/// Library tracks by last listen, newest first (at most [limit]).
final recentSongsProvider = Provider<AsyncValue<List<Song>>>((ref) {
  final history = ref.watch(listeningHistoryProvider);
  return ref.watch(songListProvider).whenData(
    (songs) => historySongs(songs, history, byCount: false),
  );
});

/// Library tracks by play count, then last listen (at most [limit]).
final mostPlayedSongsProvider = Provider<AsyncValue<List<Song>>>((ref) {
  final history = ref.watch(listeningHistoryProvider);
  return ref.watch(songListProvider).whenData(
    (songs) => historySongs(songs, history, byCount: true),
  );
});

/// How many tracks the history views list.
const int historyLimit = 100;

/// The library tracks [history] knows, ordered by last listen or by count.
/// Pure, for the providers above and their test.
List<Song> historySongs(
  List<Song> songs,
  Map<String, ListenEntry> history, {
  required bool byCount,
  int limit = historyLimit,
}) {
  final known = [
    for (final song in songs)
      if (history[song.filePath] != null) (song, history[song.filePath]!),
  ];
  known.sort((a, b) {
    if (byCount) {
      final c = b.$2.count.compareTo(a.$2.count);
      if (c != 0) return c;
    }
    return b.$2.lastPlayedMs.compareTo(a.$2.lastPlayedMs);
  });
  return [for (final (song, _) in known.take(limit)) song];
}
