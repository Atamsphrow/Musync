// The widget's state: what it shows, and that an unchanged state is not
// re-sent (each send redraws the widget).
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
