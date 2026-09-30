// Regression tests for the bundled lyrics sources.
//
// The app ships two built-in sources — LRCLIB and lyrics.ovh, the latter
// documented "On by default". For a while, a fresh install (no settings file)
// only ever queried LRCLIB: the store's fallbacks returned LRCLIB alone, and
// the settings notifier did the same. These tests pin the fallbacks to the
// full bundled list.
//
// LyricsSourceStore normally reads the app's documents directory through
// path_provider, which has no plugin in a unit test, so the file location is
// injected with a temporary file instead.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/settings/data/lyrics_source_config.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_sources_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  LyricsSourceStore storeFor(String name) => LyricsSourceStore(
    fileLocator: () async =>
        File('${tempDir.path}${Platform.pathSeparator}$name'),
  );

  List<String> idsOf(List<LyricsSourceConfig> configs) => [
    for (final config in configs) config.id,
  ];

  group('LyricsSourceStore.load — bundled defaults', () {
    test('with no file at all, both bundled sources are returned', () async {
      final loaded = await storeFor('lyrics_sources.json').load();

      expect(idsOf(loaded), ['lrclib', 'lyrics-ovh']);
      expect(loaded.every((config) => config.enabled), isTrue);
    });

    test('an unreadable file falls back to both bundled sources', () async {
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}lyrics_sources.json',
      );
      await file.writeAsString('ceci n\u2019est pas du json {{{');

      final loaded = await storeFor('lyrics_sources.json').load();

      expect(idsOf(loaded), ['lrclib', 'lyrics-ovh']);
    });

    test('a non-list payload falls back to both bundled sources', () async {
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}lyrics_sources.json',
      );
      await file.writeAsString(jsonEncode({'oops': 'not a list'}));

      final loaded = await storeFor('lyrics_sources.json').load();

      expect(idsOf(loaded), ['lrclib', 'lyrics-ovh']);
    });

    test(
      'a file written before lyrics.ovh existed gains it on read, '
      'keeping the stored flags',
      () async {
        // A settings file from when LRCLIB was the only bundled source.
        final file = File(
          '${tempDir.path}${Platform.pathSeparator}lyrics_sources.json',
        );
        await file.writeAsString(
          jsonEncode([
            {
              'id': 'lrclib',
              'name': 'LRCLIB',
              'baseUrl': 'https://lrclib.net/api',
              'enabled': false,
              'isBuiltIn': true,
              'kind': 'lrclib',
            },
          ]),
        );

        final loaded = await storeFor('lyrics_sources.json').load();

        expect(idsOf(loaded), ['lrclib', 'lyrics-ovh']);
        // The user's own toggle survives the upgrade...
        expect(
          loaded.firstWhere((config) => config.id == 'lrclib').enabled,
          isFalse,
        );
        // ...and the new bundled source arrives switched on, as documented.
        expect(
          loaded.firstWhere((config) => config.id == 'lyrics-ovh').enabled,
          isTrue,
        );
      },
    );

    test('builtInSources really is both defaults, LRCLIB first', () {
      expect(idsOf(builtInSources), ['lrclib', 'lyrics-ovh']);
    });
  });
}
