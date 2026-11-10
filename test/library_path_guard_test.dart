import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/tools/library_path_guard.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory library;
  late Directory elsewhere;
  late String song;

  setUp(() async {
    library = await Directory.systemTemp.createTemp('musync_guard_');
    elsewhere = await Directory.systemTemp.createTemp('musync_outside_');
    song = p.join(library.path, 'musique.mp3');
    await File(song).writeAsBytes([0xFF, 0xFB]);
  });

  tearDown(() async {
    await library.delete(recursive: true);
    await elsewhere.delete(recursive: true);
  });

  test('autorise un sous-dossier de la bibliothèque', () async {
    expect(
      await LibraryPathGuard.permits(p.join(library.path, 'album'), [song]),
      isTrue,
    );
  });

  test('refuse le dossier externe, le chemin relatif et ../', () async {
    expect(await LibraryPathGuard.permits(elsewhere.path, [song]), isFalse);
    expect(await LibraryPathGuard.permits('album', [song]), isFalse);
    expect(
      await LibraryPathGuard.permits(
        '${library.path}${Platform.pathSeparator}album'
        '${Platform.pathSeparator}..${Platform.pathSeparator}ailleurs',
        [song],
      ),
      isFalse,
    );
  });

  test('refuse un lien symbolique même sous le dossier autorisé', () async {
    if (Platform.isWindows) return;
    final link = Link(p.join(library.path, 'raccourci'));
    await link.create(elsewhere.path);
    expect(
      await LibraryPathGuard.permits(p.join(link.path, 'vol.mp3'), [song]),
      isFalse,
    );
  });
}
