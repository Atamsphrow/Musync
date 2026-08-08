import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:musync/features/library/data/models/song.dart';

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

  AudioPlayerService() : _player = AudioPlayer() {
    // The player drives the current index, not the other way round: skipping
    // from the notification or the lock screen never passes through this class.
    _player.currentIndexStream.listen((index) {
      if (index != null && index >= 0 && index < _queue.length) {
        _currentSong = _queue[index];
      }
    });
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
    final newQueue = queue ?? (_queue.contains(song) ? _queue : [..._queue, song]);
    final resolvedIndex = _resolveIndex(newQueue, song, index);

    final sameQueue = _listEquals(newQueue, _queue) && _player.audioSource != null;
    if (sameQueue) {
      await _player.seek(Duration.zero, index: resolvedIndex);
      await _player.play();
      return;
    }

    _queue = List.unmodifiable(newQueue);
    _currentSong = _queue.isEmpty ? null : _queue[resolvedIndex];

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

  static AudioSource _toSource(Song song) => AudioSource.file(
        song.filePath,
        tag: MediaItem(
          // MediaItem ids must be unique within the queue; the MediaStore id
          // already is.
          id: song.id.toString(),
          title: song.title,
          artist: song.artist,
          album: song.album,
          duration: song.durationValue,
          artUri: song.artworkUri,
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

  Future<void> previous() async {
    if (_player.hasPrevious) await _player.seekToPrevious();
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

  void dispose() {
    _player.dispose();
  }
}
