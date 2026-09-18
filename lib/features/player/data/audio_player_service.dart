import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:musync/core/services/audio_backend_check.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/artwork_cache.dart';

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

  /// Long-lived HTTP clients this service owns, closed in [dispose].
  ///
  /// Nothing uses this today — every source builds its own client and lives for
  /// the session. The registry exists for the one plan that would change that,
  /// P5's batch sweep: spinning up a source per album would otherwise leak one
  /// connection pool per album, quietly, for a whole sweep. A source that is
  /// handed a client can register it here so teardown has something to close.
  final List<http.Client> _httpClients = [];

  final StreamController<Song?> _currentSongController =
      StreamController<Song?>.broadcast();

  /// Held so it can be cancelled before the controller closes — see [dispose].
  late final StreamSubscription<int?> _indexSubscription;

  AudioPlayerService() : _player = AudioPlayer() {
    // The player drives the current index, not the other way round: skipping
    // from the notification or the lock screen never passes through this class.
    _indexSubscription = _player.currentIndexStream.listen((index) {
      if (index != null && index >= 0 && index < _queue.length) {
        _setCurrentSong(_queue[index]);
      }
    });
  }

  /// Registers a client so [dispose] closes it. See [_httpClients].
  void adoptHttpClient(http.Client client) => _httpClients.add(client);

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
  }

  Song? get currentSong => _currentSong;
  List<Song> get queue => _queue;
  int get currentIndex => _player.currentIndex ?? 0;
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

  /// Starts [song], optionally replacing the queue around it.
  ///
  /// Rebuilding the audio source is expensive and restarts playback, so a call
  /// that only re-selects a song already in the current queue seeks instead.
  Future<void> playSong(Song song, {List<Song>? queue, int? index}) async {
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
      await _player.play();
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
    await _warmArtwork(resolvedIndex);

    await _player.setAudioSource(
      ConcatenatingAudioSource(
        children: [for (final s in _queue) _toSource(s)],
      ),
      initialIndex: resolvedIndex,
    );
    await _player.play();
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
      await _artwork.extract(_queue[i]);
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
  Future<void> pause() => _player.pause();
  Future<void> stop() => _player.stop();
  Future<void> seekTo(Duration position) => _player.seek(position);

  Future<void> togglePlayPause() =>
      _player.playing ? _player.pause() : _player.play();

  /// Seeks by [delta], clamped to the track — seeking past the end would skip
  /// to the next song, which is never what a ±5 s button means.
  Future<void> seekBy(Duration delta) {
    final target = _player.position + delta;
    final end = _player.duration;
    if (target.isNegative) return _player.seek(Duration.zero);
    if (end != null && target > end) return _player.seek(end);
    return _player.seek(target);
  }

  Future<void> next() async {
    if (_player.hasNext) await _player.seekToNext();
  }

  /// Mirrors what every other player does with this button, and what the
  /// previous implementation did not.
  ///
  /// It read `if (hasPrevious) seekToPrevious()`, so at the head of a queue the
  /// button did nothing at all — no restart, no feedback, just a dead control.
  /// The convention (YouTube Music, Spotify, Musicolet) is two rules:
  ///
  ///   1. past ~3 s into the track, the button means "back to the start of this
  ///      track", regardless of where the queue is;
  ///   2. within the first seconds, it means "the previous track" — and when
  ///      there is none, that degrades to rule 1 rather than to nothing.
  ///
  /// The 3 s threshold is also what keeps a double-tap from being swallowed:
  /// the first tap returns to 0, the second, now inside the window, steps back.
  ///
  /// Callers are unchanged: `player_controls.dart` calls this directly.
  Future<void> previous() async {
    if (_player.position > const Duration(seconds: 3) ||
        !_player.hasPrevious) {
      return _player.seek(Duration.zero);
    }
    await _player.seekToPrevious();
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
  ///
  /// The adopted clients are closed last, and after the player: nothing here
  /// issues a request, so a client still in flight during teardown is a request
  /// already abandoned.
  Future<void> dispose() async {
    await _indexSubscription.cancel();
    await _player.dispose();
    await _currentSongController.close();
    for (final client in _httpClients) {
      client.close();
    }
    _httpClients.clear();
  }
}
