import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:musync/core/services/audio_backend_check.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/artwork_bytes_cache.dart';
import 'package:musync/features/player/data/artwork_cache.dart';
import 'package:musync/features/player/data/last_song_store.dart';
import 'package:musync/features/player/data/playback_state_store.dart';
import 'package:musync/features/player/data/queue_shuffle_order.dart';
import 'package:musync/features/player/data/volume_fade.dart';

/// A track that could not be played, as reported to the UI.
@immutable
class PlaybackFailure {
  /// The track the player was on when it failed; null when none was known.
  final Song? song;

  /// True when the file is gone from disk (moved, deleted, SD card removed),
  /// as opposed to present but unreadable.
  final bool missingFile;

  /// Whether a next track exists, so the message can offer to skip to it.
  final bool canSkip;

  const PlaybackFailure({
    required this.song,
    required this.missingFile,
    required this.canSkip,
  });

  /// What the user is told.
  String get message {
    final target = song;
    final name = target == null ? 'ce morceau' : '« ${target.title} »';
    return missingFile
        ? 'Fichier introuvable : $name a été déplacé ou supprimé. '
              'Tirez la bibliothèque vers le bas pour l’actualiser.'
        : 'Lecture impossible : $name est illisible ou corrompu.';
  }

  /// Builds the failure for [song], checking the disk for the file.
  static PlaybackFailure of(Song? song, {required bool canSkip}) {
    var missing = false;
    if (song != null) {
      try {
        missing = !File(song.filePath).existsSync();
      } catch (_) {
        // Unreadable path: report it as unreadable, not as missing.
      }
    }
    return PlaybackFailure(song: song, missingFile: missing, canSkip: canSkip);
  }
}

/// Wraps [AudioPlayer] and owns the playback queue.
///
/// Every source handed to the player carries a [MediaItem] tag: that is what
/// `just_audio_background` reads to populate the media notification and the
/// lock screen. An untagged source makes it throw at playback time, so tagging
/// is not optional here.
class AudioPlayerService {
  final AudioPlayer _player;

  /// The playback queue, observable: the queue screens' headers (track
  /// count, total length) follow it without each mutation having to tell
  /// them. Always an unmodifiable list, replaced — never mutated in place —
  /// so a change is a new value.
  final ValueNotifier<List<Song>> _queueNotifier =
      ValueNotifier<List<Song>>(const []);
  List<Song> get _queue => _queueNotifier.value;
  set _queue(List<Song> value) => _queueNotifier.value = value;

  /// The queue as a listenable, for widgets that summarise it.
  ValueListenable<List<Song>> get queueListenable => _queueNotifier;
  Song? _currentSong;

  final StreamController<Song?> _currentSongController =
      StreamController<Song?>.broadcast();

  /// The queue source currently in the player and its shuffle order, kept
  /// together so a queue mutation can tell the order where the item goes
  /// (see [QueueShuffleOrder]). Only trusted while [_player.audioSource] is
  /// still [_queueSource].
  ConcatenatingAudioSource? _queueSource;
  QueueShuffleOrder? _queueOrder;

  /// The shuffle order of [source] when it is the queue this service built.
  QueueShuffleOrder? _orderOf(AudioSource? source) =>
      identical(source, _queueSource) ? _queueOrder : null;

  /// A queue source with a [QueueShuffleOrder], not yet installed.
  static (ConcatenatingAudioSource, QueueShuffleOrder) _newQueueSource(
    List<AudioSource> children,
  ) {
    final order = QueueShuffleOrder();
    final source = ConcatenatingAudioSource(
      // Lazy preparation: the next track starts loading just before the
      // current one ends, so automatic advances are gapless instead of
      // reloading at each boundary — and the stale-position window the
      // lyrics bubble guards against gets shorter.
      useLazyPreparation: true,
      shuffleOrder: order,
      children: children,
    );
    return (source, order);
  }

  /// Playback failures the player reports on its own (see [playbackFailures]).
  final StreamController<PlaybackFailure> _failureController =
      StreamController<PlaybackFailure>.broadcast();

  /// Held so it can be cancelled before the controller closes — see [dispose].
  late final StreamSubscription<int?> _indexSubscription;

  /// Periodic position checkpoints; kept so it can be cancelled in [dispose].
  StreamSubscription<Duration>? _positionSubscription;

  /// Playback-event watch for the loop re-anchor (see [_onPlaybackEvent]).
  StreamSubscription<PlaybackEvent>? _loopWatchSubscription;

  /// Last playback event received, for the loop re-anchor comparison.
  PlaybackEvent? _lastPlaybackEvent;

  /// When this service last asked the player to seek. A playback event
  /// arriving within [_ownSeekWindow] of it is that seek's own echo, never
  /// a loop — without this, the correction's own seek(0) would re-trigger.
  DateTime? _lastServiceSeekAt;
  StreamSubscription<void>? _noisySubscription;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;

  /// Minuteur du fondu de volume du réveil (voir [VolumeFade]). Annulé par
  /// pause/stop/suivant/précédent et par tout nouveau playSong.
  Timer? _fadeTimer;

  /// Volume à restaurer quand le fondu est annulé avant la fin.
  double _fadeTargetVolume = 1.0;

  /// Settles a running [fadeOutAndPause]: true when the fade ran to the end,
  /// false when something cancelled it (pause, skip, a new track…).
  Completer<bool>? _fadeOutCompleter;

  /// Vrai quand la lecture a été mise en pause par le début d'une
  /// interruption audio (appel) : sert à décider de la reprise auto à la fin.
  bool _wasPlayingBeforeInterruption = false;

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
        // Warm the cover bytes too: _warmArtwork only runs on an
        // explicit playSong/restore, so an automatic advance used to
        // leave the new track's pane to fetch its cover at open time
        // (a visible beat of placeholder). Prefetch is a no-op when
        // the bytes are already settled.
        _artworkBytes.prefetch(_queue[index]);
        // Track change (tap, next/prev, auto-advance, notification): the
        // restored launch needs this index, not just the song.
        _persistPlaybackState();
      } else if (index != null) {
        // Never silent: a dropped index means _queue and just_audio disagree,
        // and the now-playing screen freezes on the old track while the audio
        // moves on. Loud here so the Journal shows it.
        DebugLog.instance.error(
          'Player',
          'index $index ignoré: file=${_queue.length} — '
              'désync file/audio, l\u2019écran va rester figé sur '
              '${_currentSong?.title ?? 'rien'}',
        );
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
    _loopWatchSubscription = _player.playbackEventStream.listen(
      _onPlaybackEvent,
      // just_audio reports a track it cannot open (deleted, moved, corrupt)
      // as an error on this stream. Nothing listened for it: an automatic
      // advance onto a missing file simply stopped the music, with no word
      // to the user and no line in the Journal.
      onError: _onPlaybackError,
    );
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
      // begins; resume when it ends if the track was playing before —
      // comportement intégré, sans réglage.
      _interruptionSubscription = session.interruptionEventStream.listen((
        event,
      ) {
        if (event.begin && _player.playing) {
          _wasPlayingBeforeInterruption = true;
          unawaited(pause());
        } else if (!event.begin && _wasPlayingBeforeInterruption) {
          _wasPlayingBeforeInterruption = false;
          if (_player.playing) return;
          DebugLog.instance.info('Player', 'reprise auto après interruption');
          unawaited(_player.play());
        }
      });
    } catch (e) {
      // Best-effort: playback works without it, but say so — otherwise the
      // unplug protection is silently absent.
      DebugLog.instance.warning(
        'Player',
        'Écoute du débranchement casque impossible',
        error: e,
      );
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

  /// Failures the player hits by itself — chiefly an automatic advance (or a
  /// notification skip) onto a file that is gone or unreadable. The app
  /// shows each one as a message. Failures of an explicit [playSong] are
  /// also reported to its caller.
  Stream<PlaybackFailure> get playbackFailures => _failureController.stream;

  void _onPlaybackError(Object error, StackTrace stack) {
    final song = _currentSong;
    DebugLog.instance.error(
      'Player',
      'Erreur de lecture${song == null ? '' : ' : ${song.filePath}'}',
      error: error,
      stackTrace: stack,
    );
    if (_failureController.isClosed) return;
    _failureController.add(PlaybackFailure.of(song, canSkip: _player.hasNext));
  }

  /// Whether the queue has a track after the current one.
  bool get hasNext => _player.hasNext;

  Song? get currentSong => _currentSong;
  List<Song> get queue => _queue;
  int get currentIndex => _player.currentIndex ?? 0;

  /// The song the player will play after the current one — shuffle and
  /// repeat included, via just_audio's own [AudioPlayer.nextIndex].
  /// Null at the end of the queue (repeat off). Under repeat-one it is
  /// the current track itself, so a caller that prefetches must skip it.
  Song? get nextSong {
    final index = _player.nextIndex;
    if (index == null || index < 0 || index >= _queue.length) return null;
    return _queue[index];
  }

  /// Persists the queue, the current index in it and the shuffle/repeat
  /// modes, so the next launch restores the whole playback state — not just
  /// the track. Fire-and-forget: the store never throws, and playback must
  /// never wait on the disk.
  ///
  /// The index is derived from [_currentSong]'s slot in [_queue], never from
  /// the player's index: with shuffle enabled the player's index runs in
  /// shuffled order, while the persisted queue is always the plain order and
  /// is reshuffled on restore.
  void _persistPlaybackState() {
    final queue = _queue;
    final current = _currentSong;
    var index = current == null ? 0 : queue.indexOf(current);
    if (index < 0 || queue.isEmpty) index = 0;
    if (index >= queue.length) index = queue.length - 1;
    DebugLog.instance.info(
      'Player',
      'sauvegarde état: file=${queue.length} index=$index',
    );
    unawaited(
      PlaybackStateStore().update(
        queuePaths: [for (final s in queue) s.filePath],
        index: index,
        shuffle: _player.shuffleModeEnabled,
        repeat: _player.loopMode.name,
      ),
    );
  }

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
    _currentSong = current.copyWith(title: title, artist: artist, album: album);
    if (!_currentSongController.isClosed) {
      _currentSongController.add(_currentSong);
    }
  }

  /// A file was renamed/moved on disk: the song keeps its id, only its path
  /// changes. Updates the current song and every queue entry carrying the
  /// old path, so playback never keeps pointing at a path that no longer
  /// exists. The audio source itself is untouched: just_audio already holds
  /// the open file, and the next track loads from the updated queue.
  ///
  /// Bypasses [_setCurrentSong]'s equality check on purpose, like
  /// [updateCurrentSongMetadata]: [Song.==] compares ids only, so a
  /// path-only change would look like "the same song" and never reach the
  /// UI. The queue is reassigned, never mutated in place — it is always an
  /// unmodifiable list.
  void updateSongPath(String oldPath, String newPath) {
    if (oldPath == newPath) return;
    var changed = false;
    final current = _currentSong;
    if (current != null && current.filePath == oldPath) {
      _currentSong = current.copyWith(filePath: newPath);
      if (!_currentSongController.isClosed) {
        _currentSongController.add(_currentSong);
      }
      changed = true;
    }
    if (_queue.any((s) => s.filePath == oldPath)) {
      _queue = List.unmodifiable([
        for (final s in _queue)
          s.filePath == oldPath ? s.copyWith(filePath: newPath) : s,
      ]);
      changed = true;
    }
    if (changed) _persistPlaybackState();
  }

  /// Drops the cached artworks for [song], e.g. after its cover was
  /// edited: the notification extraction re-reads the tag and the player
  /// pane re-queries MediaStore.
  Future<void> forgetArtwork(Song song) async {
    _artworkBytes.forget(song);
    await _artwork.forget(song);
  }

  /// Full-size cover bytes for the player screen, warmed by [_warmArtwork]
  /// so opening the player shows the cover on the first frame.
  ArtworkBytesCache get artworkBytes => _artworkBytes;
  final ArtworkBytesCache _artworkBytes = ArtworkBytesCache();
  bool get isShuffleEnabled => _player.shuffleModeEnabled;
  LoopMode get loopMode => _player.loopMode;
  /// Whether audio is actually advancing.
  ///
  /// Not `_player.playing` alone: just_audio leaves `playing` true once the
  /// last track of the queue has finished (`ProcessingState.completed`), so
  /// the end of a queue read as « still playing » — the main button showed
  /// Pause over silence, and the headphones automation refused to start.
  bool get isPlaying => isEffectivelyPlaying(
    playing: _player.playing,
    processingState: _player.processingState,
  );

  /// Pure rule behind [isPlaying], shared with the UI's `isPlayingProvider`.
  static bool isEffectivelyPlaying({
    required bool playing,
    required ProcessingState processingState,
  }) => playing && processingState != ProcessingState.completed;
  Duration get position => _player.position;

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
  Stream<bool> get shuffleModeEnabledStream => _player.shuffleModeEnabledStream;
  Stream<LoopMode> get loopModeStream => _player.loopModeStream;

  /// Position jumps the player reports — seek, and auto-advance to the next
  /// track (or wrap-around under [LoopMode.one]).
  ///
  /// G71 : c'est le signal exact de « fin de morceau » pour le minuteur
  /// (`SleepTimerController`) : just_audio n'émet `autoAdvance` que quand
  /// l'index change sans seek, ou quand la piste reboucle en `LoopMode.one`
  /// — jamais sur un saut manuel. `PublishSubject` : pas de rejeu à la
  /// souscription, contrairement à `playerStateStream`.
  Stream<PositionDiscontinuity> get positionDiscontinuityStream =>
      _player.positionDiscontinuityStream;

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
  ///
  /// [fadeIn], when non-null, démarre un fondu de volume progressif
  /// ([VolumeFade]) dès la lecture : utilisé par les alarmes (réveil en
  /// douceur). Tout nouveau playSong annule le fondu précédent.
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    Duration? fadeIn,
  }) => _startSong(song, queue: queue, index: index, fadeIn: fadeIn);

  /// « Aléatoire » on [queue], starting at [song] (its slot [index]): a fresh
  /// shuffled order that begins at [song] and runs through every other
  /// track. Shuffle mode must already be on.
  ///
  /// Not [playSong]: when [queue] is already the playing queue, playSong
  /// only seeks to the track inside the existing shuffled run — every track
  /// placed before it in that run was then never played.
  Future<void> playShuffled(
    Song song, {
    required List<Song> queue,
    required int index,
  }) => _startSong(song, queue: queue, index: index, reshuffle: true);

  Future<void> _startSong(
    Song song, {
    List<Song>? queue,
    int? index,
    Duration? fadeIn,
    bool reshuffle = false,
  }) {
    // Eager, not inside the gate: a sleep-timer fade-out must be silenced
    // right now, before its own completion handler looks at the player.
    final settled = _endFadeQuietly();
    final previous = _playSongGate;
    // The gate serializes the expensive, stateful part: building the audio
    // source and seeking. Starting playback stays outside it on purpose:
    // just_audio's play() future resolves only once the platform answers
    // the play request, which can lag well past the first audible note —
    // holding the gate that long would wedge every later tap on a song
    // behind the current one. The caller's future still reports play()
    // errors.
    final setup = Future.wait([settled, previous ?? Future.value()]).then(
      (_) => _playSong(song, queue: queue, index: index, reshuffle: reshuffle),
    );
    _playSongGate = setup.then<void>((_) {}, onError: (_) {});
    return setup.then((_) {
      // Volume baissé AVANT la première note : sinon le réveil hurle à plein
      // volume pendant les premières millisecondes.
      if (fadeIn != null) _startVolumeFade(fadeIn);
      return _player.play();
    });
  }

  Future<void> _playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    bool reshuffle = false,
  }) async {
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
      if (reshuffle && _player.shuffleModeEnabled) {
        await _reshuffleFrom(resolvedIndex);
      }
      await _seekWithRecord(Duration.zero, index: resolvedIndex);
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

    final children = [for (final s in _queue) _toSource(s)];
    final (queueSource, queueOrder) = _newQueueSource(children);
    try {
      await _player.setAudioSource(queueSource, initialIndex: resolvedIndex);
      _queueSource = queueSource;
      _queueOrder = queueOrder;
    } catch (_) {
      // The new queue was announced but never loaded (corrupt/missing file):
      // put the old state back so the UI, the index subscription and the real
      // source agree again, then let the caller report the failure.
      _queue = previousQueue;
      _setCurrentSong(previousSong);
      rethrow;
    }
    // The queue actually changed: the next launch restores all of it.
    _persistPlaybackState();
  }

  /// A new shuffled order for the installed queue, beginning at [child].
  ///
  /// just_audio's own [AudioPlayer.shuffle] starts the order at the
  /// *current* index, which is still the old track at this point; the
  /// queue's [QueueShuffleOrder] is told the real start instead. A new
  /// source needs none of this: just_audio shuffles it from its initial
  /// index when it is set.
  Future<void> _reshuffleFrom(int child) async {
    _orderOf(_player.audioSource)?.startNextShuffleAt(child);
    await _player.shuffle();
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
  ///
  /// Two caches, two consumers: the extracted files feed the notification,
  /// the in-memory bytes feed the player pane — warming both here is what
  /// lets the player open with its cover already drawn.
  Future<void> _warmArtwork(int from) async {
    final end = (from + _artworkLookahead).clamp(0, _queue.length);
    for (var i = from.clamp(0, _queue.length); i < end; i++) {
      _artworkBytes.prefetch(_queue[i]);
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

  /// Démarre un fondu de volume progressif : le volume part de
  /// [VolumeFade.startVolume] et monte jusqu'au volume courant en [duration].
  ///
  /// Le volume cible est capturé maintenant (le service ne gère pas le volume
  /// par ailleurs, c'est donc 1.0 sauf réglage externe). Annulé par
  /// [_cancelVolumeFade] : pause, stop, suivant/précédent, nouveau playSong.
  void _startVolumeFade(Duration duration) {
    _cancelVolumeFade();
    _fadeTargetVolume = _player.volume <= 0 ? 1.0 : _player.volume;
    final target = _fadeTargetVolume;
    unawaited(_player.setVolume(VolumeFade.startVolume * target));
    final start = DateTime.now();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      final elapsed = DateTime.now().difference(start);
      if (elapsed >= duration) {
        unawaited(_player.setVolume(target));
        timer.cancel();
        _fadeTimer = null;
        return;
      }
      unawaited(
        _player.setVolume(VolumeFade.volumeAt(elapsed, duration) * target),
      );
    });
  }

  /// Arrête le fondu en cours sans toucher au volume, et règle un
  /// [fadeOutAndPause] en cours comme annulé. Rend le volume à restaurer,
  /// ou null quand aucun fondu ne tournait.
  ///
  /// Le volume reste où le fondu l'avait laissé : c'est à l'appelant de le
  /// remettre, au bon moment (voir [_endFadeQuietly]).
  double? _stopVolumeFade() {
    final timer = _fadeTimer;
    if (timer == null) return null;
    timer.cancel();
    _fadeTimer = null;
    final pending = _fadeOutCompleter;
    _fadeOutCompleter = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    return _fadeTargetVolume;
  }

  /// Annule le fondu en cours et restaure le volume cible tout de suite :
  /// une pause en plein fondu suivie d'une reprise ne doit pas laisser la
  /// lecture à volume réduit.
  void _cancelVolumeFade() {
    final restore = _stopVolumeFade();
    if (restore != null) unawaited(_restoreVolume(restore));
  }

  /// Puts the volume a fade had moved back to [volume]. Best-effort: a
  /// failed setVolume must not fail the transport action around it.
  Future<void> _restoreVolume(double volume) async {
    try {
      await _player.setVolume(volume);
    } catch (_) {
      // The next fade, or the next track, sets it again.
    }
  }

  /// Ends a running fade before a skip or a new track, without a burst.
  ///
  /// The sleep timer's fade-out is silenced first — paused, then the volume
  /// restored — because restoring first played the still-running track at
  /// full volume for a moment (and, on a skip, started the next one loud
  /// before the timer paused it): bedtime means silence. A wake-up fade-in
  /// is simply brought to full volume, as before.
  Future<void> _endFadeQuietly() async {
    final fadingOut = _fadeOutCompleter != null;
    final restore = _stopVolumeFade();
    if (restore == null) return;
    if (fadingOut && _player.playing) {
      try {
        await _player.pause();
      } catch (_) {
        // Restored below either way; the music was nearly silent anyway.
      }
    }
    await _restoreVolume(restore);
  }

  /// Lowers the volume to silence over [duration], then pauses and puts the
  /// volume back where it was — the sleep timer's soft landing, instead of
  /// the music stopping mid-phrase.
  ///
  /// Any transport action meanwhile (pause, skip, a new track) cancels the
  /// fade and restores the volume once the audio is paused (see
  /// [_endFadeQuietly]); the call then returns false. True when it paused.
  Future<bool> fadeOutAndPause(Duration duration) async {
    _cancelVolumeFade();
    if (!isPlaying) return true; // Nothing to land: already silent.
    if (duration <= Duration.zero) {
      await pause();
      return true;
    }
    final from = _player.volume <= 0 ? 1.0 : _player.volume;
    _fadeTargetVolume = from;
    final completer = Completer<bool>();
    _fadeOutCompleter = completer;
    final clock = Stopwatch()..start();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      final t = clock.elapsedMilliseconds / duration.inMilliseconds;
      if (t >= 1) {
        timer.cancel();
        _fadeTimer = null;
        _fadeOutCompleter = null;
        if (!completer.isCompleted) completer.complete(true);
        return;
      }
      // Quadratic, like the wake-up fade: the ear hears volume
      // logarithmically, so a linear ramp sounds like nothing, then a cliff.
      final left = 1 - t;
      unawaited(_player.setVolume(from * left * left));
    });
    final ranToEnd = await completer.future;
    if (!ranToEnd) return false;
    await pause();
    await _player.setVolume(from);
    return true;
  }

  /// Stops a running [fadeOutAndPause] and restores the volume — the sleep
  /// timer was switched off or changed mid-fade.
  void cancelFadeOut() {
    if (_fadeOutCompleter != null) _cancelVolumeFade();
  }

  /// Reprend la lecture.
  ///
  /// [fadeIn], when non-null, starts a progressive volume fade
  /// ([VolumeFade]) once playback has resumed: the alarm path
  /// (`PlayTool` without query) resumes this way so the wake-up is
  /// gentle, like [playSong] does for a fresh track. A null fade means
  /// an immediate resume at the current volume, as before.
  Future<void> play({Duration? fadeIn}) async {
    // At the end of the queue just_audio sits on `completed`, where play()
    // is a silent no-op: the button did nothing. Replay the track the queue
    // stopped on, from its start — never jump elsewhere, so the sync editor
    // keeps the track it is editing.
    if (_player.processingState == ProcessingState.completed) {
      await _seekWithRecord(Duration.zero, index: _player.currentIndex);
    }
    await _player.play();
    if (fadeIn != null) _startVolumeFade(fadeIn);
  }

  /// Persists the current track and position right now, outside the 15s
  /// periodic checkpoint (which only runs while playing). Used on pause and
  /// when the app goes to the background: a swipe-away kill loses everything
  /// after the last checkpoint otherwise.
  Future<void> checkpointPosition() async {
    final song = _currentSong;
    if (song == null) return;
    try {
      await LastSongStore().save(song.filePath, _player.position);
    } catch (_) {
      // The checkpoint is best-effort; callers must never fail because of it.
    }
  }

  Future<void> pause() async {
    // Checkpoint: the app can be killed while paused, and the periodic save
    // only runs while playing. Awaited before pausing, so a kill during the
    // pause transition cannot lose the position — but a failing save must
    // never block the actual pause (e.g. headphones unplugged with a full
    // disk: the music still has to stop).
    //
    // A fade in progress stops where it is, and its volume comes back only
    // once the audio is paused: restoring it first played the end of the
    // sleep timer's fade-out at full volume for as long as the checkpoint
    // write took.
    final restore = _stopVolumeFade();
    try {
      await checkpointPosition();
      await _player.pause();
    } finally {
      if (restore != null) await _restoreVolume(restore);
    }
  }

  Future<void> stop() async {
    final restore = _stopVolumeFade();
    _wasPlayingBeforeInterruption = false;
    try {
      await _player.stop();
    } finally {
      if (restore != null) await _restoreVolume(restore);
    }
  }

  /// Re-opens the playback state from when the app was last closed: the whole
  /// queue (matched by path against the library, in the persisted order),
  /// the current track at its saved position, and the shuffle/repeat modes.
  /// Called once, after the library has loaded, so tracks can be found by
  /// their paths.
  ///
  /// Returns true when something was restored. Never starts playback by
  /// itself: the track waits, paused, for the user to press play.
  Future<bool> restoreLastPlayed(List<Song> library) async {
    if (_currentSong != null) return false;
    final saved = await LastSongStore().load();
    final path = saved.path;
    if (path == null || path.isEmpty) return false;
    final state = await PlaybackStateStore().load();

    // Resolve the persisted queue against the library. Files that disappeared
    // since (deleted, moved) are dropped; the order stays the persisted one.
    final byPath = <String, Song>{for (final s in library) s.filePath: s};
    final queue = <Song>[
      for (final p in state.queuePaths)
        if (byPath.containsKey(p)) byPath[p]!,
    ];
    DebugLog.instance.info(
      'Player',
      'restauration: persistés=${state.queuePaths.length} '
          'retrouvés=${queue.length} biblio=${library.length} '
          'index=${state.index} shuffle=${state.shuffle} repeat=${state.repeat}',
    );
    if (queue.isEmpty) {
      // No persisted queue (first launch on this version, or an unreadable
      // file): fall back to the single last track, as before.
      DebugLog.instance.info(
        'Player',
        'restauration: file vide, repli sur le dernier morceau seul',
      );
      final single = byPath[path];
      if (single == null) return false;
      queue.add(single);
    }
    var index = queue.indexWhere((s) => s.filePath == path);
    if (index < 0) {
      // The last track itself is gone; restart where the queue says.
      index = state.index.clamp(0, queue.length - 1);
    }
    final match = queue[index];
    try {
      AudioBackendCheck.ensureIntercepted();
      _queue = List.unmodifiable(queue);
      await _warmArtwork(index);
      // A share (or any explicit play) may have claimed the player while the
      // library and the artwork were loading: the entry guard above is stale
      // by now. Re-check before the source goes in — the last setAudioSource
      // wins, and it must be the explicit choice, not the restoration.
      //
      // The queue is left alone on purpose: the concurrent playSong() already
      // installed its own queue (and announced its track), so rolling back to
      // the pre-restore queue would desync _queue from just_audio — the
      // now-playing screen would then freeze on the next track change.
      if (_currentSong != null) {
        DebugLog.instance.info(
          'Player',
          'restauration: annulée, lecture explicite entre-temps',
        );
        return false;
      }
      final (queueSource, queueOrder) = _newQueueSource([
        for (final s in queue) _toSource(s),
      ]);
      await _player.setAudioSource(queueSource, initialIndex: index);
      _queueSource = queueSource;
      _queueOrder = queueOrder;
      // Modes before the seek: the seek lands in plain order, and enabling
      // shuffle afterwards keeps the current item (same as toggleShuffle).
      final repeat = switch (state.repeat) {
        'all' => LoopMode.all,
        'one' => LoopMode.one,
        _ => LoopMode.off,
      };
      await _player.setLoopMode(repeat);
      // The saved position belongs to the saved track: when the queue fell
      // back to a different track (saved file gone), seeking the new track
      // to the old one's position would start it mid-way for no reason.
      var target = match.filePath == saved.path
          ? saved.position
          : Duration.zero;
      if (target.isNegative) target = Duration.zero;
      final duration = _player.duration;
      if (duration != null && target >= duration) target = Duration.zero;
      await _seekWithRecord(target);
      if (state.shuffle) {
        await _player.shuffle();
        await _player.setShuffleModeEnabled(true);
      }
      // Announced (and persisted) after the seek, so the stored position is
      // the restored one rather than zero — and the stored queue matches the
      // filtered one above.
      _setCurrentSong(match);
      _persistPlaybackState();
      DebugLog.instance.info(
        'Player',
        'restauration OK: file=${queue.length} index=$index '
            'morceau=${match.title}',
      );
      return true;
    } catch (_) {
      DebugLog.instance.info('Player', 'restauration: échec setAudioSource');
      _queue = const [];
      return false;
    }
  }

  Future<void> seekTo(Duration position) => _seekWithRecord(position);

  /// Every seek this service asks for, recorded so [_onPlaybackEvent] can
  /// tell our own seeks' echoes apart from a loop. Notification and lock
  /// screen seeks bypass this class (see the constructor comment) and so
  /// are not recorded — a backward notification seek in the last seconds
  /// of a looping track could in principle read as a loop; rare, and the
  /// consequence is only a restart of the track.
  Future<void> _seekWithRecord(Duration position, {int? index}) {
    _lastServiceSeekAt = DateTime.now();
    return _player.seek(position, index: index);
  }

  /// How close to the track end the previous position must sit for a
  /// backward jump to read as a loop rather than an ordinary seek.
  static const Duration _loopEndWindow = Duration(seconds: 5);

  /// Smallest backward jump that counts as a loop. Steady-state events
  /// (pause/resume, buffering) sit within milliseconds of the previous
  /// sample; a loop jumps by seconds — except a stale anchor parked within
  /// a second of the end, which is why the threshold is this low rather
  /// than several seconds.
  static const Duration _loopJumpThreshold = Duration(milliseconds: 500);

  /// Events from our own seeks are ignored for this long after the seek
  /// call: the seek's own discontinuity event is a backward jump on the
  /// same index by construction, and must not read as a loop.
  static const Duration _ownSeekWindow = Duration(seconds: 2);

  /// Pure loop-back test, exposed for tests.
  ///
  /// True when a playback event looks like the loop point of a repeating
  /// track rather than anything the user did: same item, looping enabled,
  /// playing, previous position near the end, and the new position jumping
  /// backwards — while no service seek is in flight.
  @visibleForTesting
  static bool shouldCorrectLoopAnchor({
    required Duration prevExtrapolated,
    required Duration eventUpdatePosition,
    required int? prevIndex,
    required int? eventIndex,
    required bool loopEnabled,
    required Duration? duration,
    required bool playing,
    required DateTime? lastServiceSeekAt,
    required DateTime now,
  }) {
    if (!playing || !loopEnabled) return false;
    if (prevIndex == null || prevIndex != eventIndex) return false;
    if (duration == null || prevExtrapolated < duration - _loopEndWindow) {
      return false;
    }
    if (eventUpdatePosition > prevExtrapolated - _loopJumpThreshold) {
      return false;
    }
    if (lastServiceSeekAt != null &&
        now.difference(lastServiceSeekAt) < _ownSeekWindow) {
      return false;
    }
    return true;
  }

  /// Mirrors just_audio's position getter for the previous event: extrapolate
  /// with the wall clock while playing and ready, else the frozen position.
  Duration _extrapolatedPosition(PlaybackEvent event, DateTime now) {
    if (_player.playing && _player.processingState == ProcessingState.ready) {
      final result =
          event.updatePosition +
          now.difference(event.updateTime) * _player.speed;
      final duration = event.duration ?? _player.duration;
      if (duration == null || result <= duration) return result;
      return duration;
    }
    return event.updatePosition;
  }

  /// A new index can inherit just_audio's stale seek target from the old
  /// track if no READY transition occurred. Detect only a nonzero anchor
  /// identical to the old one and never a recent deliberate user seek.
  @visibleForTesting
  static bool shouldCorrectIndexAnchor({
    required int? previousIndex,
    required int? currentIndex,
    required Duration previousPosition,
    required Duration currentPosition,
    required bool playing,
    required DateTime? lastServiceSeekAt,
    required DateTime now,
  }) {
    if (!playing || previousIndex == null || currentIndex == null ||
        previousIndex == currentIndex) {
      return false;
    }
    if (lastServiceSeekAt != null &&
        now.difference(lastServiceSeekAt) < _ownSeekWindow) {
      return false;
    }
    if (previousPosition < const Duration(seconds: 3) ||
        currentPosition < const Duration(seconds: 3)) {
      return false;
    }
    return (previousPosition - currentPosition).abs() <
        const Duration(milliseconds: 750);
  }

  /// Loop re-anchor: just_audio's Android player remembers the last seek
  /// target (`seekPos`) and only clears it on a READY state transition.
  /// A seek on a buffered local file often produces none, so the stale
  /// target survives — and at a LoopMode.one loop the discontinuity event
  /// broadcasts it as the position. Dart then extrapolates from that wrong
  /// anchor at the right speed: lyrics (and the progress bar) run desynced
  /// for the whole looped play, until the next user seek. Detecting the
  /// loop here and seeking to zero resets the stale target to the one
  /// value that is always right at a loop point, fixing lyrics and bar
  /// together without forking just_audio. The seek lands where the audio
  /// already is (the loop just restarted it), so it is a re-anchor, not
  /// an audible jump.
  void _onPlaybackEvent(PlaybackEvent event) {
    final now = DateTime.now();
    final prev = _lastPlaybackEvent;
    _lastPlaybackEvent = event;
    if (prev == null) return;
    if (shouldCorrectIndexAnchor(
      previousIndex: prev.currentIndex,
      currentIndex: event.currentIndex,
      previousPosition: _extrapolatedPosition(prev, now),
      currentPosition: event.updatePosition,
      playing: _player.playing,
      lastServiceSeekAt: _lastServiceSeekAt,
      now: now,
    )) {
      DebugLog.instance.warning(
        'Player',
        'Ancre de position héritée du morceau précédent : seek(0)',
      );
      unawaited(_seekWithRecord(Duration.zero, index: event.currentIndex));
      return;
    }
    final duration = event.duration ?? _player.duration;
    if (shouldCorrectLoopAnchor(
      prevExtrapolated: _extrapolatedPosition(prev, now),
      eventUpdatePosition: event.updatePosition,
      prevIndex: prev.currentIndex,
      eventIndex: event.currentIndex,
      loopEnabled:
          _player.loopMode == LoopMode.one || _player.loopMode == LoopMode.all,
      duration: duration,
      playing: _player.playing,
      lastServiceSeekAt: _lastServiceSeekAt,
      now: now,
    )) {
      DebugLog.instance.info(
        'Player',
        'Boucle détectée (ancre périmée '
            '${event.updatePosition.inMilliseconds}ms) — recalage seek(0)',
      );
      unawaited(_seekWithRecord(Duration.zero));
    }
  }

  Future<void> togglePlayPause() => isPlaying ? pause() : play();

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
  Future<void> seekBy(Duration delta) => _seekWithRecord(
    clampSeekBy(
      position: _player.position,
      delta: delta,
      duration: _player.duration,
    ),
  );

  Future<void> next() async {
    await _endFadeQuietly();
    DebugLog.instance.info(
      'Player',
      'next: file=${_queue.length} idx=${_player.currentIndex} hasNext=${_player.hasNext}',
    );
    if (_player.hasNext) await _player.seekToNext();
  }

  Future<void> previous() async {
    await _endFadeQuietly();
    DebugLog.instance.info(
      'Player',
      'prev: file=${_queue.length} idx=${_player.currentIndex} hasPrev=${_player.hasPrevious}',
    );
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
  /// Synchronous half of a queue reorder: validates and applies the new order
  /// to the in-memory queue immediately, returning the validated indexes
  /// (null when the reorder is a no-op).
  ///
  /// `ReorderableListView` animates the displaced rows from the very next
  /// frame after `onReorderItem` fires, so the new order must be visible
  /// synchronously — awaiting the just_audio mirror first is what made the
  /// rows jump instead of sliding. The async mirror follows via
  /// [reorderQueueApply].
  (int, int)? reorderQueueSync(int oldIndex, int newIndex) {
    final source = _player.audioSource;
    if (source is! ConcatenatingAudioSource) return null;
    final length = _queue.length;
    if (oldIndex < 0 || oldIndex >= length) return null;
    if (newIndex < 0 || newIndex >= length) return null;
    if (oldIndex == newIndex) return null;
    final updated = List<Song>.of(_queue);
    updated.insert(newIndex, updated.removeAt(oldIndex));
    _queue = List.unmodifiable(updated);
    return (oldIndex, newIndex);
  }

  /// Async half of a queue reorder: mirrors the move in just_audio and
  /// re-aligns the playing index. Safe to run in the background — the UI
  /// already shows the new order.
  Future<void> reorderQueueApply(int oldIndex, int newIndex) async {
    final source = _player.audioSource;
    if (source is! ConcatenatingAudioSource) return;
    // The list the user drags is the plain order; under shuffle the moved
    // track keeps its place in the shuffled run instead of landing at a
    // random one (just_audio's default re-inserts moves randomly).
    _orderOf(source)?.keepSlotOnNextMove();
    await source.move(oldIndex, newIndex);
    await _reconcileCurrentIndex();
  }

  /// Reorders the queue: synchronous state update, then the player mirror.
  ///
  /// The playing track keeps playing: only its slot changes, never its
  /// identity, so no track-change is announced and the lyrics/bubble keep
  /// their state. Invalid indexes are a silent no-op — this is called from a
  /// drag gesture, never with a reason to crash.
  ///
  /// Prefer the split pair ([reorderQueueSync] + [reorderQueueApply]) from a
  /// drag callback, where the UI must reflect the move synchronously.
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    final moved = reorderQueueSync(oldIndex, newIndex);
    if (moved == null) return;
    await reorderQueueApply(moved.$1, moved.$2);
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
      // The queue just died: persist the empty state so a relaunch does not
      // resurrect the removed tracks.
      _persistPlaybackState();
      return;
    }
    if (wasCurrent) {
      // Seek to the neighbour in the old source *before* removing the playing
      // child: what the platform does when the current child disappears
      // under it is not something to depend on.
      final target = index < updated.length ? index : updated.length - 1;
      final oldTarget = index < updated.length ? index + 1 : index - 1;
      _setCurrentSong(updated[target]);
      await _seekWithRecord(Duration.zero, index: oldTarget);
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
  ///
  /// False when [song] is the track playing right now: nothing can come
  /// sooner than that, and moving it onto its own slot used to re-place it
  /// at random in the shuffled run — changing what played next.
  Future<bool> playNext(Song song) async {
    final source = _player.audioSource;
    if (source is! ConcatenatingAudioSource || _queue.isEmpty) {
      await playSong(song, queue: [song], index: 0);
      return true;
    }
    final insertAt = (currentIndex + 1).clamp(0, _queue.length);
    final existing = _queue.indexOf(song);
    if (existing >= 0 && existing == currentIndex) return false;
    final shuffling = _player.shuffleModeEnabled;
    // Already exactly next: nothing to do. Under shuffle « next » is the
    // shuffled successor, not the plain-order neighbour.
    final alreadyNext = shuffling
        ? existing >= 0 && _player.nextIndex == existing
        : existing == insertAt;
    if (alreadyNext) return true;
    // Under shuffle, just_audio would drop the track at a random spot of the
    // shuffled run: « Lire ensuite » then played it whenever. Pin it right
    // after the current track instead.
    if (shuffling) _orderOf(source)?.placeNextInsertAfter(currentIndex);
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
    return true;
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
    // Queue mutations (reorder, remove, play-next) land here: persist before
    // the alignment check below, which early-returns when already aligned.
    _persistPlaybackState();
    final expected = _queue.indexOf(current);
    if (expected < 0 || _player.currentIndex == expected) return;
    try {
      await _seekWithRecord(_player.position, index: expected);
    } catch (_) {
      // Best-effort, see above.
    }
  }

  Future<void> toggleShuffle() async {
    final enabling = !_player.shuffleModeEnabled;
    // Reshuffling before enabling avoids replaying the order from last time.
    if (enabling) await _player.shuffle();
    await _player.setShuffleModeEnabled(enabling);
    _persistPlaybackState();
  }

  Future<void> cycleRepeatMode() async {
    final next = switch (_player.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await _player.setLoopMode(next);
    _persistPlaybackState();
  }

  /// Order matters here.
  ///
  /// Closing the controller first left the index subscription alive over a
  /// closed sink: one last event from the player being torn down called `add`
  /// on it and threw `Cannot add new events after calling close` from inside a
  /// stream callback, where nothing was waiting to catch it.
  Future<void> dispose() async {
    _cancelVolumeFade();
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _loopWatchSubscription?.cancel();
    _loopWatchSubscription = null;
    await _noisySubscription?.cancel();
    _noisySubscription = null;
    await _interruptionSubscription?.cancel();
    _interruptionSubscription = null;
    await _indexSubscription.cancel();
    await _player.dispose();
    await _currentSongController.close();
    await _failureController.close();
    _queueNotifier.dispose();
  }
}
