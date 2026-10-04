import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:musync/core/services/audio_backend_check.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/artwork_cache.dart';
import 'package:musync/features/player/data/last_song_store.dart';

/// Wraps [AudioPlayer] and owns the playback queue.
///
/// Every source handed to the player carries a [MediaItem] tag: that is what
/// `just_audio_background` reads to populate the media notification and the
/// lock screen. An untagged source makes it throw at playback time, so tagging
/// is not optional here.
class AudioPlayerService {
  final AudioPlayer _player;

  List<Song> _queue = const [];
  Song? _currentSong;

  final StreamController<Song?> _currentSongController =
      StreamController<Song?>.broadcast();

  /// Held so it can be cancelled before the controller closes — see [dispose].
  late final StreamSubscription<int?> _indexSubscription;

  /// Periodic position checkpoints; kept so it can be cancelled in [dispose].
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<void>? _noisySubscription;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;

  /// How often the current position is persisted while playing, so the
  /// next launch resumes where the track actually stopped — not where the
  /// previous track change left it.
  static const Duration _positionSaveInterval = Duration(seconds: 15);

  DateTime _lastPositionSave = DateTime.fromMillisecondsSinceEpoch(0);

  AudioPlayerService() : _player = AudioPlayer() {
    // The player drives the current index, not the other way round: skipping
    // from the notification or the lock screen never passes through this class.
    _indexSubscription = _player.currentIndexStream.listen((index) {
      if (index != null && index >= 0 && index < _queue.length) {
        _setCurrentSong(_queue[index]);
      }
    });
    // Periodic checkpoint of the position. Track changes alone persist too
    // early (the new track's position, near zero); this keeps the stored
    // position close to where playback really is.
    _positionSubscription = _player.positionStream.listen((position) {
      final song = _currentSong;
      if (song == null || !_player.playing || position <= Duration.zero) {
        return;
      }
      final now = DateTime.now();
      if (now.difference(_lastPositionSave) < _positionSaveInterval) return;
      _lastPositionSave = now;
      unawaited(LastSongStore().save(song.filePath, position));
    });
    unawaited(_watchBecomingNoisy());
  }

  /// Headphones unplugged (or Bluetooth dropped) mid-playback: pause at
  /// once instead of blasting the room on the speaker. Phone calls and other
  /// audio-focus losses are handled below too (just_audio does not do it).
  Future<void> _watchBecomingNoisy() async {
    try {
      final session = await AudioSession.instance;
      // Declares music playback to the OS, so calls and other interruptions
      // are actually reported to us.
      await session.configure(const AudioSessionConfiguration.music());
      _noisySubscription = session.becomingNoisyEventStream.listen((_) {
        if (_player.playing) unawaited(pause());
      });
      // just_audio does not handle audio focus itself: without this listener
      // the music kept playing over phone calls. Pause when the interruption
      // begins; no auto-resume when it ends — the user decides.
      _interruptionSubscription =
          session.interruptionEventStream.listen((event) {
        if (event.begin && _player.playing) unawaited(pause());
      });
    } catch (e) {
      // Best-effort: playback works without it, but say so — otherwise the
      // unplug protection is silently absent.
      DebugLog.instance.warning('Player', 'Écoute du débranchement casque impossible', error: e);
    }
  }

  /// Emits whenever the playing track actually changes.
  ///
  /// A dedicated stream rather than something derived from the index, because
  /// the index is not enough to tell: playing the first track of one list and
  /// then the first track of another emits `0` twice. Nothing downstream saw a
  /// change, so the mini player and the now-playing screen kept showing the
  /// previous track while the audio had already moved on.
  Stream<Song?> get currentSongStream => _currentSongController.stream;

  /// Single point where the current track changes, so no path can move the
  /// audio without telling the UI.
  void _setCurrentSong(Song? song) {
    if (song == _currentSong) return;
    _currentSong = song;
    // Guarded: `add` on a closed controller throws, and the player can emit one
    // last index while it is being torn down.
    if (!_currentSongController.isClosed) _currentSongController.add(song);
    // Persisted so the next launch can re-open this track (#4). Best-effort: a
    // failed write costs the next launch resuming from no track, which is
    // exactly what the app did before this.
    //
    // The new track is saved with an explicit zero position: `_player.position`
    // is still the previous track's position when this runs, so persisting it
    // here would resume the new track from the old one's spot.
    if (song != null) {
      unawaited(LastSongStore().save(song.filePath, Duration.zero));
    }
  }

  Song? get currentSong => _currentSong;
  List<Song> get queue => _queue;
  int get currentIndex => _player.currentIndex ?? 0;

  /// Updates the current song's display metadata after a tag edit, without
  /// touching playback. The file itself is unchanged — only its tags were
  /// rewritten, so the audio source stays as it is.
  ///
  /// Bypasses [_setCurrentSong]'s equality check on purpose: [Song.==]
  /// compares ids only, so a metadata-only change would look like "the same
  /// song" and never reach the UI.
  void updateCurrentSongMetadata({
    required String title,
    required String artist,
    required String album,
  }) {
    final current = _currentSong;
    if (current == null) return;
    _currentSong = current.copyWith(
      title: title,
      artist: artist,
      album: album,
    );
    if (!_currentSongController.isClosed) {
      _currentSongController.add(_currentSong);
    }
  }

  /// Drops the cached notification artwork for [song], e.g. after its cover
  /// was edited. The next extraction re-reads the tag.
  Future<void> forgetArtwork(Song song) => _artwork.forget(song);
  bool get isShuffleEnabled => _player.shuffleModeEnabled;
  LoopMode get loopMode => _player.loopMode;
  bool get isPlaying => _player.playing;
  Duration get position => _player.position;

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
  Stream<bool> get shuffleModeEnabledStream => _player.shuffleModeEnabledStream;
  Stream<LoopMode> get loopModeStream => _player.loopModeStream;

  /// Serializes overlapping [playSong] calls (double-tap, fast list taps).
  ///
  /// Each call waits for the previous one to finish before rebuilding the
  /// queue, so two quick taps can never interleave a stale queue rebuild with
  /// a newer one and leave the player on the wrong track. The gate itself is
  /// error-proofed, so one failed call does not wedge every later call; the
  /// caller's own future still reports its error.
  Future<void>? _playSongGate;

  /// Starts [song], optionally replacing the queue around it.
  ///
  /// Rebuilding the audio source is expensive and restarts playback, so a call
  /// that only re-selects a song already in the current queue seeks instead.
  Future<void> playSong(Song song, {List<Song>? queue, int? index}) {
    final previous = _playSongGate;
    // The gate serializes the expensive, stateful part: building the audio
    // source and seeking. Starting playback stays outside it on purpose:
    // just_audio's play() future resolves only once the platform answers
    // the play request, which can lag well past the first audible note —
    // holding the gate that long would wedge every later tap on a song
    // behind the current one. The caller's future still reports play()
    // errors.
    final setup = (previous ?? Future.value())
        .then((_) => _playSong(song, queue: queue, index: index));
    _playSongGate = setup.then<void>((_) {}, onError: (_) {});
    return setup.then((_) => _player.play());
  }

  Future<void> _playSong(Song song, {List<Song>? queue, int? index}) async {
    final newQueue =
        queue ?? (_queue.contains(song) ? _queue : [..._queue, song]);
    final resolvedIndex = _resolveIndex(newQueue, song, index);

    final sameQueue =
        _listEquals(newQueue, _queue) && _player.audioSource != null;
    if (sameQueue) {
      // Announce the move before seeking. `currentIndexStream` will report it
      // too, but only once the player gets there — and not at all when the
      // index happens to be unchanged. Leaving it to that stream is what left
      // the old track on screen after picking a different one from the same
      // list.
      _setCurrentSong(newQueue.isEmpty ? null : newQueue[resolvedIndex]);
      await _player.seek(Duration.zero, index: resolvedIndex);
      return;
    }

    // Before the audio source is built, and therefore before just_audio
    // resolves the platform for the first time.
    //
    // This is the moment that decided whether a media notification could ever
    // exist, and it was being lost: the platform is resolved lazily on the
    // first load, by which time the plugin registrant has re-run and replaced
    // the background wrapper with the plain one. Restoring it here is what puts
    // playback back through audio_service.
    AudioBackendCheck.ensureIntercepted();

    final previousQueue = _queue;
    final previousSong = _currentSong;
    _queue = List.unmodifiable(newQueue);
    final target = _queue.isEmpty ? null : _queue[resolvedIndex];
    _setCurrentSong(target);

    // The track about to play, plus a short run behind it.
    //
    // A `MediaItem` is fixed when the source is built, so a track whose artwork
    // is not in the cache by now will show none in the notification for this
    // whole queue — even after the player advances to it. Extracting only the
    // first track therefore meant every automatic advance lost its thumbnail.
    //
    // Extracting the whole queue is not the answer either: a play from the
    // library hands over every track on the phone, and reading a cover out of
    // each before a single note sounds would take seconds. So a window, and a
    // small one — the cache keys by album, so an album queue costs exactly one
    // read and a shuffled one costs at most [_artworkLookahead].
    //
    // Deliberately not awaited: the first note must not wait on artwork
    // extraction. The covers land in the cache for the notification and for
    // automatic advances; the MediaItem tags carry whatever is cached by the
    // time the source is built.
    unawaited(_warmArtwork(resolvedIndex));

    try {
      await _player.setAudioSource(
        ConcatenatingAudioSource(
          // Lazy preparation: the next track starts loading just before the
          // current one ends, so automatic advances are gapless instead of
          // reloading at each boundary — and the stale-position window the
          // lyrics bubble guards against gets shorter.
          useLazyPreparation: true,
          children: [for (final s in _queue) _toSource(s)],
        ),
        initialIndex: resolvedIndex,
      );
    } catch (_) {
      // The new queue was announced but never loaded (corrupt/missing file):
      // put the old state back so the UI, the index subscription and the real
      // source agree again, then let the caller report the failure.
      _queue = previousQueue;
      _setCurrentSong(previousSong);
      rethrow;
    }
  }

  /// Prefers the caller's index, since a library list can legitimately hold the
  /// same track twice; falls back to a lookup, then to the head of the queue.
  static int _resolveIndex(List<Song> queue, Song song, int? index) {
    if (index != null && index >= 0 && index < queue.length) return index;
    final found = queue.indexOf(song);
    return found >= 0 ? found : 0;
  }

  /// Cover art for the notification, pulled from the tag rather than from
  /// MediaStore's removed album-art provider. See [ArtworkCache].
  final ArtworkCache _artwork = ArtworkCache();

  /// How many tracks past the one being started get their cover read now.
  ///
  /// Enough to cover a few automatic advances, which is where the thumbnail
  /// used to disappear. Keyed by album inside the cache, so this is four reads
  /// in the worst case and one for an album played in order.
  static const int _artworkLookahead = 4;

  /// Reads the covers the queue is about to need, ignoring failures.
  Future<void> _warmArtwork(int from) async {
    final end = (from + _artworkLookahead).clamp(0, _queue.length);
    for (var i = from.clamp(0, _queue.length); i < end; i++) {
      try {
        await _artwork.extract(_queue[i]);
      } catch (_) {
        // A corrupt file must not kill the warmup of the rest of the queue.
      }
    }
  }

  AudioSource _toSource(Song song) => AudioSource.file(
    song.filePath,
    tag: MediaItem(
      // MediaItem ids must be unique within the queue; the MediaStore id
      // already is.
      id: song.id.toString(),
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.durationValue,
      artUri: _artwork.cached(song),
    ),
  );

  static bool _listEquals(List<Song> a, List<Song> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> play() => _player.play();

  Future<void> pause() async {
    // Checkpoint: the app can be killed while paused, and the periodic save
    // only runs while playing. Awaited before pausing, so a kill during the
    // pause transition cannot lose the position — but a failing save must
    // never block the actual pause (e.g. headphones unplugged with a full
    // disk: the music still has to stop).
    final song = _currentSong;
    if (song != null) {
      try {
        await LastSongStore().save(song.filePath, _player.position);
      } catch (_) {
        // The checkpoint is best-effort; the pause below is not.
      }
    }
    await _player.pause();
  }

  Future<void> stop() => _player.stop();

  /// Re-opens the track playing when the app was last closed, paused at the
  /// saved position. Called once, after the library has loaded, so the track
  /// can be found by its path.
  ///
  /// Returns true when a track was restored. Never starts playback by itself:
  /// the track waits, paused, for the user to press play.
  Future<bool> restoreLastPlayed(List<Song> library) async {
    if (_currentSong != null) return false;
    final saved = await LastSongStore().load();
    final path = saved.path;
    if (path == null || path.isEmpty) return false;
    Song? match;
    for (final song in library) {
      if (song.filePath == path) {
        match = song;
        break;
      }
    }
    if (match == null) return false;
    try {
      AudioBackendCheck.ensureIntercepted();
      _queue = List.unmodifiable([match]);
      await _warmArtwork(0);
      await _player.setAudioSource(
        ConcatenatingAudioSource(children: [_toSource(match)]),
      );
      var target = saved.position;
      if (target.isNegative) target = Duration.zero;
      final duration = _player.duration;
      if (duration != null && target >= duration) target = Duration.zero;
      await _player.seek(target);
      // Announced (and persisted) after the seek, so the stored position is
      // the restored one rather than zero.
      _setCurrentSong(match);
      return true;
    } catch (_) {
      return false;
    }
  }
  Future<void> seekTo(Duration position) => _player.seek(position);

  Future<void> togglePlayPause() =>
      _player.playing ? pause() : _player.play();

  /// How far short of the track end a forward seek is allowed to land.
  ///
  /// Seeking to exactly the duration completes the track in just_audio, so a
  /// +5 s jump near the end would skip to the next song instead of landing
  /// near the end of this one.
  static const Duration _endOfTrackMargin = Duration(milliseconds: 250);

  /// Pure clamp used by [seekBy], exposed for tests.
  ///
  /// A target at or past the duration lands on `duration - margin` rather than
  /// on the duration itself; a negative target lands on zero.
  @visibleForTesting
  static Duration clampSeekBy({
    required Duration position,
    required Duration delta,
    required Duration? duration,
  }) {
    final target = position + delta;
    if (target.isNegative) return Duration.zero;
    if (duration != null && target >= duration) {
      final clamped = duration - _endOfTrackMargin;
      return clamped.isNegative ? Duration.zero : clamped;
    }
    return target;
  }

  /// Seeks by [delta], clamped to the track — seeking past the end would skip
  /// to the next song, which is never what a ±5 s button means.
  Future<void> seekBy(Duration delta) => _player.seek(
    clampSeekBy(
      position: _player.position,
      delta: delta,
      duration: _player.duration,
    ),
  );

  Future<void> next() async {
    if (_player.hasNext) await _player.seekToNext();
  }

  Future<void> previous() async {
    if (_player.hasPrevious) await _player.seekToPrevious();
  }

  /// Moves the track at [oldIndex] to [newIndex] in the playback queue.
  ///
  /// Both [_queue] and the underlying [ConcatenatingAudioSource] are updated,
  /// so the audio that follows a move stays the audio the UI lists. [newIndex]
  /// is the track's final position: `ReorderableListView.onReorderItem`
  /// reports exactly that (the framework adjusts for the removed item), so no
  /// index shifting is needed on either side — the UI passes the value
  /// through, this method owns the player state.
  ///
  /// The playing track keeps playing: only its slot changes, never its
  /// identity, so no track-change is announced and the lyrics/bubble keep
  /// their state. Invalid indexes are a silent no-op — this is called from a
  /// drag gesture, never with a reason to crash.
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    final source = _player.audioSource;
    if (source is! ConcatenatingAudioSource) return;
    final length = _queue.length;
    if (oldIndex < 0 || oldIndex >= length) return;
    if (newIndex < 0 || newIndex >= length) return;
    if (oldIndex == newIndex) return;
    final updated = List<Song>.of(_queue);
    updated.insert(newIndex, updated.removeAt(oldIndex));
    _queue = List.unmodifiable(updated);
    await source.move(oldIndex, newIndex);
    await _reconcileCurrentIndex();
  }

  /// Removes the track at [index] from the playback queue.
  ///
  /// When the removed track is the one playing, playback continues with the
  /// track that slides into its slot — or the new tail when the tail was
  /// removed — restarted from zero. When the queue becomes empty, playback
  /// stops and the player is left with an empty source, so a later play
  /// cannot resurrect the removed track. The player is never left on an
  /// invalid index; invalid indexes are a silent no-op.
  Future<void> removeFromQueue(int index) async {
    final source = _player.audioSource;
    if (source is! ConcatenatingAudioSource) return;
    if (index < 0 || index >= _queue.length) return;
    final wasCurrent = index == currentIndex;
    final updated = List<Song>.of(_queue)..removeAt(index);
    _queue = List.unmodifiable(updated);
    if (updated.isEmpty) {
      await _player.stop();
      // Best-effort: without this, the stopped player still holds the removed
      // track's source and a later play would bring it back from the dead.
      try {
        await _player.setAudioSource(
          ConcatenatingAudioSource(children: const []),
        );
      } catch (_) {
        // The queue is empty and playback stopped either way.
      }
      _setCurrentSong(null);
      return;
    }
    if (wasCurrent) {
      // Seek to the neighbour in the old source *before* removing the playing
      // child: what the platform does when the current child disappears
      // under it is not something to depend on.
      final target = index < updated.length ? index : updated.length - 1;
      final oldTarget = index < updated.length ? index + 1 : index - 1;
      _setCurrentSong(updated[target]);
      await _player.seek(Duration.zero, index: oldTarget);
      await source.removeAt(index);
    } else {
      await source.removeAt(index);
    }
    await _reconcileCurrentIndex();
  }

  /// Queues [song] to play right after the current track.
  ///
  /// When the song is already in the queue it is moved instead of duplicated —
  /// "play next" on an already-queued track means "sooner", not "twice". With
  /// no queue loaded at all, this simply starts playback of the song.
  Future<void> playNext(Song song) async {
    final source = _player.audioSource;
    if (source is! ConcatenatingAudioSource || _queue.isEmpty) {
      await playSong(song, queue: [song], index: 0);
      return;
    }
    final insertAt = (currentIndex + 1).clamp(0, _queue.length);
    final existing = _queue.indexOf(song);
    if (existing == insertAt) return; // Already exactly next: nothing to do.
    final updated = List<Song>.of(_queue);
    if (existing >= 0) {
      final moved = updated.removeAt(existing);
      // Removing a slot before the insertion point shifts it down by one.
      final target = existing < insertAt ? insertAt - 1 : insertAt;
      updated.insert(target, moved);
      _queue = List.unmodifiable(updated);
      await source.move(existing, target);
    } else {
      updated.insert(insertAt, song);
      _queue = List.unmodifiable(updated);
      await source.insert(insertAt, _toSource(song));
    }
    await _reconcileCurrentIndex();
  }

  /// Re-aligns the player's index with [_queue] after an in-place mutation.
  ///
  /// The platform usually follows moves/inserts/removals on its own, but its
  /// index event can lag behind the mutation; seeking explicitly to the
  /// current track's slot at the same position is a no-op when already
  /// aligned and a repair when not. Never throws: worst case the UI corrects
  /// itself on the next platform event.
  Future<void> _reconcileCurrentIndex() async {
    final current = _currentSong;
    if (current == null || _queue.isEmpty) return;
    final expected = _queue.indexOf(current);
    if (expected < 0 || _player.currentIndex == expected) return;
    try {
      await _player.seek(_player.position, index: expected);
    } catch (_) {
      // Best-effort, see above.
    }
  }

  Future<void> toggleShuffle() async {
    final enabling = !_player.shuffleModeEnabled;
    // Reshuffling before enabling avoids replaying the order from last time.
    if (enabling) await _player.shuffle();
    await _player.setShuffleModeEnabled(enabling);
  }

  Future<void> cycleRepeatMode() async {
    final next = switch (_player.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await _player.setLoopMode(next);
  }

  /// Order matters here.
  ///
  /// Closing the controller first left the index subscription alive over a
  /// closed sink: one last event from the player being torn down called `add`
  /// on it and threw `Cannot add new events after calling close` from inside a
  /// stream callback, where nothing was waiting to catch it.
  Future<void> dispose() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _noisySubscription?.cancel();
    _noisySubscription = null;
    await _interruptionSubscription?.cancel();
    _interruptionSubscription = null;
    await _indexSubscription.cancel();
    await _player.dispose();
    await _currentSongController.close();
  }
}
