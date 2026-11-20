/// The Dart half of the home-screen widget (Android): tells it what plays —
/// title, artist, cover — and runs its Previous / Play-Pause / Next.
///
/// The native half is `MusyncWidgetProvider` + `WidgetBridge`. The channel
/// lives on the engine audio_service keeps with the playback, so the widget
/// follows the music with the UI closed.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';

/// What the widget shows: null [title] means « nothing playing ».
@immutable
class HomeWidgetState {
  final String? title;
  final String? artist;
  final bool playing;

  /// Which cover [artwork] is — the track and the cover cache's revision,
  /// so an edited cover counts as a new one. Null: no cover known yet (the
  /// widget shows the app icon). Two states with the same key carry the
  /// same picture, which is what equality and [payload] go by: the bytes
  /// themselves are never compared, nor re-sent for a play/pause.
  final Object? artworkKey;

  /// The cover's encoded bytes (the player's own, from MediaStore); null
  /// for a track without one.
  final Uint8List? artwork;

  const HomeWidgetState({
    this.title,
    this.artist,
    this.playing = false,
    this.artworkKey,
    this.artwork,
  });

  factory HomeWidgetState.of(
    Song? song, {
    required bool playing,
    Object? artworkKey,
    Uint8List? artwork,
  }) => HomeWidgetState(
    title: song?.title,
    artist: song?.artist,
    playing: song != null && playing,
    artworkKey: song == null ? null : artworkKey,
    artwork: song == null ? null : artwork,
  );

  /// The message for the widget. [withArtwork]: the cover changed, its
  /// bytes go along (`null` clears it); otherwise the key is absent and the
  /// widget keeps the picture it has.
  Map<String, Object?> toMap({bool withArtwork = false}) => {
    'title': title,
    'artist': artist,
    'playing': playing,
    if (withArtwork) 'artwork': artworkKey == null ? null : artwork,
  };

  /// What to send after [previous] (null: nothing sent yet).
  Map<String, Object?> payload(HomeWidgetState? previous) => toMap(
    withArtwork: previous == null || previous.artworkKey != artworkKey,
  );

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetState &&
      other.title == title &&
      other.artist == artist &&
      other.playing == playing &&
      other.artworkKey == artworkKey;

  @override
  int get hashCode => Object.hash(title, artist, playing, artworkKey);
}

class HomeWidgetBridge {
  HomeWidgetBridge(this._service, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.atamsphrow.musync/widget';

  final AudioPlayerService _service;
  final MethodChannel _channel;
  HomeWidgetState? _lastSent;
  bool _started = false;

  /// Installs the handler for the widget's buttons. Android only: elsewhere
  /// there is no widget, and the channel has no other side.
  void start() {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    _channel.setMethodCallHandler(_onCall);
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'action') return null;
    try {
      switch (call.arguments) {
        case 'previous':
          await _service.previous();
        case 'toggle':
          // Not awaited: play()'s future follows the playback itself.
          unawaited(_service.togglePlayPause());
        case 'next':
          await _service.next();
      }
    } catch (error) {
      DebugLog.instance.warning(
        'Widget',
        'Commande du widget impossible (${call.arguments})',
        error: error,
      );
    }
    return null;
  }

  /// Sends what [song] shows: at once, with its cover when the player has
  /// it already (it is prefetched as the track starts), then again with the
  /// cover once it is read — unless the track has changed meanwhile.
  Future<void> pushSong(Song? song, {required bool playing}) async {
    if (!_started) return;
    if (song == null) return push(HomeWidgetState.of(null, playing: false));
    final covers = _service.artworkBytes;
    final key = (song.id, covers.revision.value);
    if (covers.isResolved(song)) {
      return push(
        HomeWidgetState.of(
          song,
          playing: playing,
          artworkKey: key,
          artwork: covers.peek(song),
        ),
      );
    }
    await push(HomeWidgetState.of(song, playing: playing));
    final bytes = await covers.load(song);
    final now = _service.currentSong;
    if (now?.id != song.id || covers.revision.value != key.$2) return;
    await push(
      HomeWidgetState.of(
        now,
        playing: _service.isPlaying,
        artworkKey: key,
        artwork: bytes,
      ),
    );
  }

  /// Sends [state] to the widget, once per change.
  Future<void> push(HomeWidgetState state) async {
    if (!_started || state == _lastSent) return;
    final message = state.payload(_lastSent);
    _lastSent = state;
    try {
      await _channel.invokeMethod<void>('update', message);
    } on MissingPluginException {
      // No native side (tests, a platform without the widget).
    } catch (error) {
      DebugLog.instance.warning(
        'Widget',
        'Mise à jour du widget impossible',
        error: error,
      );
    }
  }

  void dispose() {
    if (_started) _channel.setMethodCallHandler(null);
  }
}

/// The bridge, fed from the player: started once by the app root.
final homeWidgetBridgeProvider = Provider<HomeWidgetBridge>((ref) {
  final service = ref.watch(audioPlayerServiceProvider);
  final bridge = HomeWidgetBridge(service);
  void push() => unawaited(
    bridge.pushSong(
      ref.read(currentSongProvider),
      playing: ref.read(isPlayingProvider),
    ),
  );
  ref.listen<Song?>(currentSongProvider, (_, _) => push());
  ref.listen<bool>(isPlayingProvider, (_, _) => push());
  // A cover edited while it plays: the widget gets the new one at once.
  final revision = service.artworkBytes.revision;
  revision.addListener(push);
  ref.onDispose(() {
    revision.removeListener(push);
    bridge.dispose();
  });
  return bridge;
});

/// Starts the bridge and sends the current state. Call once, from the root.
void startHomeWidgetBridge(WidgetRef ref) {
  final bridge = ref.read(homeWidgetBridgeProvider)..start();
  unawaited(
    bridge.pushSong(
      ref.read(currentSongProvider),
      playing: ref.read(isPlayingProvider),
    ),
  );
}
