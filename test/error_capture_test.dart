// Everything that goes wrong reaching the Journal.
//
// The two channels tested here are the ones that were silent: a Riverpod
// provider that fails — which crashes nothing, so nothing reported it — and the
// deduplication that keeps a per-track failure from flooding a 400-entry buffer
// and pushing out the errors worth reading.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/error_capture.dart';

/// Fails on build.
final _throwing = Provider<int>((ref) => throw StateError('cassé au build'));

/// Builds fine and resolves to an error — the shape nearly every failure in this
/// app takes, since the scan and every settings file are async.
final _rejecting = FutureProvider<int>(
  (ref) async => throw StateError('futur rejeté'),
);

final _fine = Provider<int>((ref) => 1);

ProviderContainer _watched() {
  final container = ProviderContainer(
    observers: const [LoggingProviderObserver()],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(DebugLog.instance.clear);

  group('provider failures reach the log', () {
    test('a provider that throws on build', () {
      final container = _watched();

      expect(() => container.read(_throwing), throwsStateError);

      final entries = DebugLog.instance.entries;
      expect(entries, isNotEmpty);
      expect(entries.first.level, LogLevel.error);
      expect(entries.first.source, 'Provider');
      expect(entries.first.details, contains('cassé au build'));
    });

    test('an async provider that resolves to an error', () async {
      // This is the one that was invisible: nothing is uncaught, the screen just
      // renders the exception as text.
      final container = _watched();

      await expectLater(container.read(_rejecting.future), throwsStateError);

      expect(
        DebugLog.instance.entries.any(
          (e) =>
              e.level == LogLevel.error && e.details!.contains('futur rejeté'),
        ),
        isTrue,
      );
    });

    test('a provider that works logs nothing', () {
      final container = _watched();
      container.read(_fine);
      expect(DebugLog.instance.isEmpty, isTrue);
    });

    test('the same error is not logged twice as it propagates', () async {
      // A failed scan is carried forward by every provider that depends on it.
      // Logging on each rebuild would turn one failure into a page of them.
      final container = _watched();
      try {
        await container.read(_rejecting.future);
      } catch (_) {
        // Expected.
      }
      final after = DebugLog.instance.entries.length;

      container.read(_rejecting);
      container.read(_rejecting);

      expect(DebugLog.instance.entries.length, after);
    });
  });

  group('once', () {
    test('reports the first and drops the rest', () {
      // 1876 tracks with artwork Flutter cannot decode would otherwise post
      // 1876 identical lines into a buffer of 400.
      for (var i = 0; i < 50; i++) {
        DebugLog.instance.once(
          'pochette',
          LogLevel.info,
          'Thème',
          'Pochette non décodable',
        );
      }

      expect(DebugLog.instance.entries, hasLength(1));
    });

    test('different keys are different reports', () {
      DebugLog.instance.once('a', LogLevel.info, 'X', 'un');
      DebugLog.instance.once('b', LogLevel.info, 'X', 'deux');

      expect(DebugLog.instance.entries, hasLength(2));
    });

    test('clearing the log lets a key report again', () {
      // Otherwise emptying the log to reproduce a problem would hide the very
      // line the user was trying to capture.
      DebugLog.instance.once('a', LogLevel.warning, 'X', 'un');
      DebugLog.instance.clear();
      DebugLog.instance.once('a', LogLevel.warning, 'X', 'un');

      expect(DebugLog.instance.entries, hasLength(1));
    });

    test('it does not suppress ordinary entries', () {
      DebugLog.instance.once('a', LogLevel.info, 'X', 'répétable');
      DebugLog.instance.error('X', 'une vraie erreur');
      DebugLog.instance.error('X', 'une vraie erreur');

      expect(DebugLog.instance.entries, hasLength(3));
    });
  });

  group('the report', () {
    test('carries every level, not just errors', () {
      // The Journal tab filters what it shows; the copied report must not, or
      // the lines just before a failure — usually the ones that explain it —
      // would be missing from the very thing someone sends on.
      DebugLog.instance.info('X', 'un détail');
      DebugLog.instance.warning('X', 'une alerte');
      DebugLog.instance.error('X', 'une erreur');

      final report = DebugLog.instance.report();
      expect(report, contains('un détail'));
      expect(report, contains('une alerte'));
      expect(report, contains('une erreur'));
    });
  });
}
