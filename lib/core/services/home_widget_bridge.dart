/// The Dart half of the home-screen widget (Android): tells it what plays,
/// and runs its Previous / Play-Pause / Next.
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

  const HomeWidgetState({this.title, this.artist, this.playing = false});

  factory HomeWidgetState.of(Song? song, {required bool playing}) => HomeWidgetState(
    title: song?.title,
    artist: song?.artist,
    playing: song != null && playing,
  );

  Map<String, Object?> toMap() => {
    'title': title,
    'artist': artist,
    'playing': playing,
  };

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetState &&
      other.title == title &&
      other.artist == artist &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(title, artist, playing);
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

  /// Sends [state] to the widget, once per change.
  Future<void> push(HomeWidgetState state) async {
    if (!_started || state == _lastSent) return;
    _lastSent = state;
    try {
      await _channel.invokeMethod<void>('update', state.toMap());
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
  final bridge = HomeWidgetBridge(ref.watch(audioPlayerServiceProvider));
  void push() => unawaited(
    bridge.push(
      HomeWidgetState.of(
        ref.read(currentSongProvider),
        playing: ref.read(isPlayingProvider),
      ),
    ),
  );
  ref.listen<Song?>(currentSongProvider, (_, _) => push());
  ref.listen<bool>(isPlayingProvider, (_, _) => push());
  ref.onDispose(bridge.dispose);
  return bridge;
});

/// Starts the bridge and sends the current state. Call once, from the root.
void startHomeWidgetBridge(WidgetRef ref) {
  final bridge = ref.read(homeWidgetBridgeProvider)..start();
  unawaited(
    bridge.push(
      HomeWidgetState.of(
        ref.read(currentSongProvider),
        playing: ref.read(isPlayingProvider),
      ),
    ),
  );
}
