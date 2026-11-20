// The queue header's summary line: track count and total length.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/ui/queue_screen.dart';

Song _song(int id, Duration length) => Song(
      id: id,
      title: 'T$id',
      artist: 'A',
      album: 'B',
      duration: length.inMilliseconds,
      filePath: '/music/$id.mp3',
    );

void main() {
  test('one track, under an hour', () {
    expect(
      queueSummary([_song(1, const Duration(minutes: 3, seconds: 40))]),
      '1 morceau · 3 min',
    );
  });

  test('several tracks past an hour', () {
    final queue = [
      for (var i = 0; i < 25; i++) _song(i, const Duration(minutes: 4)),
    ];
    expect(queueSummary(queue), '25 morceaux · 1 h 40');
  });

  test('unknown durations count as zero, not negative', () {
    expect(
      queueSummary([
        _song(1, const Duration(minutes: 2)),
        _song(2, const Duration(milliseconds: -1)),
      ]),
      '2 morceaux · 2 min',
    );
  });
}
