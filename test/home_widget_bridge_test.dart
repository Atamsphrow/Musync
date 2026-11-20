// The widget's state: what it shows, and that an unchanged state is not
// re-sent (each send redraws the widget).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/services/home_widget_bridge.dart';
import 'package:musync/features/library/data/models/song.dart';

void main() {
  const song = Song(
    id: 1,
    title: 'Titre',
    artist: 'Artiste',
    album: 'Album',
    duration: 1000,
    filePath: '/music/1.mp3',
  );

  test('a song and its playing flag', () {
    expect(HomeWidgetState.of(song, playing: true).toMap(), {
      'title': 'Titre',
      'artist': 'Artiste',
      'playing': true,
    });
  });

  test('no song is never « playing »', () {
    final state = HomeWidgetState.of(null, playing: true);
    expect(state.title, isNull);
    expect(state.playing, isFalse);
  });

  group('cover', () {
    final bytes = Uint8List.fromList([1, 2, 3]);

    test('sent with the first message, and when it changes', () {
      final first = HomeWidgetState.of(
        song,
        playing: false,
        artworkKey: (1, 0),
        artwork: bytes,
      );
      expect(first.payload(null)['artwork'], bytes);

      final edited = HomeWidgetState.of(
        song,
        playing: false,
        artworkKey: (1, 1),
        artwork: Uint8List.fromList([4]),
      );
      expect(edited.payload(first)['artwork'], [4]);
    });

    test('not re-sent for a play/pause: the widget keeps its picture', () {
      final paused = HomeWidgetState.of(
        song,
        playing: false,
        artworkKey: (1, 0),
        artwork: bytes,
      );
      final playing = HomeWidgetState.of(
        song,
        playing: true,
        artworkKey: (1, 0),
        artwork: bytes,
      );
      expect(playing.payload(paused).containsKey('artwork'), isFalse);
    });

    test('a new track without a known cover clears the old one', () {
      final before = HomeWidgetState.of(
        song,
        playing: true,
        artworkKey: (1, 0),
        artwork: bytes,
      );
      final next = HomeWidgetState.of(song.copyWith(id: 2), playing: true);
      final message = next.payload(before);
      expect(message.containsKey('artwork'), isTrue);
      expect(message['artwork'], isNull);
    });

    test('compared by key, never by bytes', () {
      expect(
        HomeWidgetState.of(
          song,
          playing: true,
          artworkKey: (1, 0),
          artwork: Uint8List.fromList([1]),
        ),
        HomeWidgetState.of(
          song,
          playing: true,
          artworkKey: (1, 0),
          artwork: Uint8List.fromList([1]),
        ),
      );
    });

    test('no song: no cover', () {
      final state = HomeWidgetState.of(
        null,
        playing: false,
        artworkKey: (1, 0),
        artwork: bytes,
      );
      expect(state.artworkKey, isNull);
      expect(state.artwork, isNull);
    });
  });

  test('value equality, so an unchanged state is not re-sent', () {
    expect(
      HomeWidgetState.of(song, playing: false),
      HomeWidgetState.of(song.copyWith(), playing: false),
    );
    expect(
      HomeWidgetState.of(song, playing: false),
      isNot(HomeWidgetState.of(song, playing: true)),
    );
  });
}
