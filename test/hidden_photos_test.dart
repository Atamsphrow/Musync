// The order of the hidden pictures, and the cycle through them.
//
// The asset discovery itself needs a real bundle and is left to the app; what is
// worth pinning down here is the ordering, because a plain string sort would put
// `tatiana10` before `tatiana2` and make the cycle jump about for no reason
// anyone could see.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/settings/data/hidden_photos.dart';

void main() {
  group('ordering', () {
    List<String> sorted(List<String> keys) =>
        [...keys]..sort(HiddenPhotos.compareByNumber);

    test('numbers sort as numbers, not as text', () {
      expect(
        sorted([
          'assets/images/tatiana10.jpg',
          'assets/images/tatiana2.jpg',
          'assets/images/tatiana1.jpg',
        ]),
        [
          'assets/images/tatiana1.jpg',
          'assets/images/tatiana2.jpg',
          'assets/images/tatiana10.jpg',
        ],
      );
    });

    test('an unnumbered one comes first', () {
      // It is the file that existed before anybody thought to number them.
      expect(
        sorted([
          'assets/images/tatiana3.jpg',
          'assets/images/tatiana.jpg',
        ]).first,
        'assets/images/tatiana.jpg',
      );
    });

    test('the order is total, so it cannot wobble between runs', () {
      // Same number, different extension: the tie-break has to be decisive or
      // the cycle would change order from one launch to the next.
      final a = sorted([
        'assets/images/tatiana2.png',
        'assets/images/tatiana2.jpg',
      ]);
      final b = sorted([
        'assets/images/tatiana2.jpg',
        'assets/images/tatiana2.png',
      ]);
      expect(a, b);
    });

    test('a long list keeps its numeric order end to end', () {
      final keys = [
        for (final n in [7, 3, 12, 1, 20, 2, 11]) 'assets/images/tatiana$n.jpg',
      ];

      expect(sorted(keys), [
        for (final n in [1, 2, 3, 7, 11, 12, 20]) 'assets/images/tatiana$n.jpg',
      ]);
    });
  });

  group('what is not a hidden picture', () {
    test('the owner\'s own photographs are never in the cycle', () async {
      // The whole point: the owner's picture is what the view opens on, and it
      // must never be reached by tapping.
      final photos = await HiddenPhotos.all();
      expect(photos, isNot(contains('assets/images/owner.png')));
      expect(photos, isNot(contains('assets/images/owner_full.jpg')));
    });
  });

  group('the cycle is remembered between launches', () {
    late Directory dir;

    final photos = [
      for (final n in [1, 2, 3]) 'assets/images/tatiana$n.jpg',
    ];

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('musync_cursor_test');
      HiddenPhotos.store = PhotoCursorStore(root: dir);
      HiddenPhotos.resetForTest();
    });

    tearDown(() async {
      HiddenPhotos.store = const PhotoCursorStore();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('stopping at the third one resumes at the fourth', () async {
      // The request, literally: three shown, app closed, and the fourth is what
      // comes back — not the first.
      final four = [
        for (final n in [1, 2, 3, 4]) 'assets/images/tatiana$n.jpg',
      ];

      for (var i = 0; i < 3; i++) {
        expect(await HiddenPhotos.advanceThrough(four), four[i]);
      }

      // A cold start: the process is gone, only the file remains.
      HiddenPhotos.resetForTest();
      expect(await HiddenPhotos.advanceThrough(four), four[3]);
    });

    test('the end wraps round to the first', () async {
      for (final expected in photos) {
        expect(await HiddenPhotos.advanceThrough(photos), expected);
      }
      HiddenPhotos.resetForTest();
      expect(await HiddenPhotos.advanceThrough(photos), photos.first);
    });

    test('no file yet means the first one', () async {
      expect(await HiddenPhotos.advanceThrough(photos), photos.first);
    });

    test('a position past the end of a shortened list still resolves', () async {
      // Someone removes a picture between two launches. The stored position now
      // points past the end, and must not throw.
      await PhotoCursorStore(root: dir).write(9);
      HiddenPhotos.resetForTest();
      expect(await HiddenPhotos.advanceThrough(photos), photos[0]);
    });

    test('an unreadable file restarts rather than throwing', () async {
      await File(
        '${dir.path}${Platform.pathSeparator}ui_state.json',
      ).writeAsString('{ this is not json');
      HiddenPhotos.resetForTest();
      expect(await HiddenPhotos.advanceThrough(photos), photos.first);
    });

    test('an empty list hands out nothing and records nothing', () async {
      expect(await HiddenPhotos.advanceThrough(const []), isNull);
      expect(await PhotoCursorStore(root: dir).read(), 0);
    });

    test('the file keeps anything else it holds', () async {
      // It is named for interface state in general, so a sibling key is the
      // expected case, not a hypothetical one.
      final file = File('${dir.path}${Platform.pathSeparator}ui_state.json');
      await file.writeAsString('{"somethingElse":"kept"}');

      await PhotoCursorStore(root: dir).write(2);
      expect(await file.readAsString(), contains('"somethingElse":"kept"'));
      expect(await PhotoCursorStore(root: dir).read(), 2);
    });

    test('a missing directory is created rather than swallowed', () async {
      final nested = Directory('${dir.path}${Platform.pathSeparator}gone');
      await PhotoCursorStore(root: nested).write(1);
      expect(await PhotoCursorStore(root: nested).read(), 1);
    });
  });
}
