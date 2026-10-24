import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/ui/widgets/song_artwork.dart';

void main() {
  test('concurrent requests share one fetch; result is kept', () async {
    var calls = 0;
    final cache = ThumbnailCache(fetch: (id) async {
      calls++;
      return Uint8List.fromList([id]);
    });
    final a = cache.entryFor(1);
    final b = cache.entryFor(1);
    expect(identical(a, b), isTrue);
    await a.future;
    expect(calls, 1);
    expect(cache.entryFor(1).isDone, isTrue);
    expect(identical(cache.entryFor(1).bytes, a.bytes), isTrue);
  });

  test('"no artwork" is remembered', () async {
    var calls = 0;
    final cache = ThumbnailCache(fetch: (id) async {
      calls++;
      return null;
    });
    await cache.entryFor(7).future;
    await cache.entryFor(7).future;
    expect(calls, 1);
  });

  test('errors are not cached', () async {
    var calls = 0;
    final cache = ThumbnailCache(fetch: (id) async {
      calls++;
      throw StateError('denied');
    });
    expect(await cache.entryFor(3).future, isNull);
    expect(await cache.entryFor(3).future, isNull);
    expect(calls, 2);
  });

  test('least recently used entry is evicted at capacity', () async {
    var calls = 0;
    final cache = ThumbnailCache(
      capacity: 2,
      fetch: (id) async {
        calls++;
        return Uint8List(1);
      },
    );
    await cache.entryFor(1).future;
    await cache.entryFor(2).future;
    await cache.entryFor(1).future; // 1 becomes most recent
    await cache.entryFor(3).future; // evicts 2
    expect(cache.length, 2);
    await cache.entryFor(1).future;
    expect(calls, 3);
    await cache.entryFor(2).future;
    expect(calls, 4);
  });
}
