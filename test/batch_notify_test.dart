import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/providers/batch_provider.dart';

void main() {
  group('shouldNotifyBatchDone', () {
    test('screen visible and app foreground: no notification', () {
      expect(shouldNotifyBatchDone(true, true), isFalse);
    });

    test('left the page: notify', () {
      expect(shouldNotifyBatchDone(false, true), isTrue);
    });

    test('HOME with the batch route still current: notify', () {
      // RouteAware alone misses HOME — the route stays current while the
      // app is backgrounded, so the foreground state must count too.
      expect(shouldNotifyBatchDone(true, false), isTrue);
    });

    test('both gone: notify', () {
      expect(shouldNotifyBatchDone(false, false), isTrue);
    });
  });
}
