// The player pane's cover cache: one MediaStore query per track per
// session, a synchronous answer once settled, and a forget that forces a
// re-query after a cover edit. The platform channel is replaced by a
// counting fake — the cache's contract is what is asserted, not
// MediaStore itself.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/artwork_bytes_cache.dart';
import 'package:on_audio_query/on_audio_query.dart';

class _FakeAudioQuery extends OnAudioQuery {
  int calls = 0;
  Uint8List? result;
  bool fail = false;

  @override
  Future<Uint8List?> queryArtwork(
    int id,
    ArtworkType type, {
    ArtworkFormat? format,
    int? size,
    int? quality,
  }) async {
    calls++;
    if (fail) throw StateError('MediaStore down');
    return result;
  }
}

Song _song(int id) => Song(
      id: id,
      title: 'Title $id',
      artist: 'Artist',
      album: 'Album',
      duration: 1000,
      filePath: '/music/$id.mp3',
    );

void main() {
  group('ArtworkBytesCache', () {
    late _FakeAudioQuery query;
    late ArtworkBytesCache cache;

    setUp(() {
      query = _FakeAudioQuery()..result = Uint8List.fromList([1, 2, 3]);
      cache = ArtworkBytesCache(query: query);
    });

    test('one query per track, shared while in flight', () async {
      final song = _song(1);
      final first = cache.load(song);
      final second = cache.load(song);
      expect(identical(first, second), isTrue);
      await first;
      await cache.load(song);
      expect(query.calls, 1);
    });

    test('peek answers synchronously once settled', () async {
      final song = _song(2);
      expect(cache.isResolved(song), isFalse);
      await cache.load(song);
      expect(cache.isResolved(song), isTrue);
      expect(cache.peek(song), Uint8List.fromList([1, 2, 3]));
    });

    test('a coverless track settles as resolved-null, no re-query',
        () async {
      query.result = null;
      final song = _song(3);
      expect(await cache.load(song), isNull);
      expect(cache.isResolved(song), isTrue);
      expect(cache.peek(song), isNull);
      await cache.load(song);
      expect(query.calls, 1);
    });

    test('a failed query settles as no cover instead of throwing',
        () async {
      query.fail = true;
      final song = _song(4);
      expect(await cache.load(song), isNull);
      expect(cache.isResolved(song), isTrue);
    });

    test('forget forces a fresh query', () async {
      final song = _song(5);
      await cache.load(song);
      cache.forget(song);
      expect(cache.isResolved(song), isFalse);
      await cache.load(song);
      expect(query.calls, 2);
    });

    test('prefetch warms without a caller awaiting it', () async {
      final song = _song(6);
      cache.prefetch(song);
      await Future<void>.delayed(Duration.zero);
      expect(cache.isResolved(song), isTrue);
      expect(query.calls, 1);
      // A second prefetch is a no-op once settled.
      cache.prefetch(song);
      expect(query.calls, 1);
    });
  });
}
