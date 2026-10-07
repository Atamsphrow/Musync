// Regression tests for the bundled lyrics sources.
//
// The app ships one built-in source: LRCLIB. lyrics.ovh used to be bundled
// "on by default", but the service proved too unreliable for that — it is
// now a one-tap preset in the Sources tab, added back as a regular entry.
// These tests pin the fallbacks to the bundled list, and the migration that
// drops the legacy bundled lyrics.ovh entry from existing settings files.
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

  Future<void> writeSources(List<Map<String, Object?>> entries) async {
    final file = File(
      '${tempDir.path}${Platform.pathSeparator}lyrics_sources.json',
    );
    await file.writeAsString(jsonEncode(entries));
  }

  List<String> idsOf(List<LyricsSourceConfig> configs) => [
    for (final config in configs) config.id,
  ];

  group('LyricsSourceStore.load — bundled defaults', () {
    test('with no file at all, only LRCLIB is returned', () async {
      final loaded = await storeFor('lyrics_sources.json').load();

      expect(idsOf(loaded), ['lrclib']);
      expect(loaded.every((config) => config.enabled), isTrue);
    });

    test('an unreadable file falls back to LRCLIB alone', () async {
      await writeSources([
        {'oops': 'not a list'},
      ]);
      // Overwrite with actual garbage: the helper above writes a list.
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}lyrics_sources.json',
      );
      await file.writeAsString('ceci n\u2019est pas du json {{{');

      final loaded = await storeFor('lyrics_sources.json').load();

      expect(idsOf(loaded), ['lrclib']);
    });

    test('a non-list payload falls back to LRCLIB alone', () async {
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}lyrics_sources.json',
      );
      await file.writeAsString(jsonEncode({'oops': 'not a list'}));

      final loaded = await storeFor('lyrics_sources.json').load();

      expect(idsOf(loaded), ['lrclib']);
    });

    test(
      'the legacy bundled lyrics.ovh entry is dropped on read',
      () async {
        // A settings file from when lyrics.ovh was bundled on by default.
        await writeSources([
          {
            'id': 'lrclib',
            'name': 'LRCLIB',
            'baseUrl': 'https://lrclib.net/api',
            'enabled': true,
            'isBuiltIn': true,
            'kind': 'lrclib',
          },
          {
            'id': 'lyrics-ovh',
            'name': 'lyrics.ovh',
            'baseUrl': 'https://api.lyrics.ovh',
            'enabled': true,
            'isBuiltIn': true,
            'kind': 'lyricsOvh',
          },
        ]);

        final loaded = await storeFor('lyrics_sources.json').load();

        expect(idsOf(loaded), ['lrclib']);
      },
    );

    test(
      'a user re-added lyrics.ovh survives the migration',
      () async {
        // Same id, but not marked built-in: the user put the preset back.
        await writeSources([
          {
            'id': 'lrclib',
            'name': 'LRCLIB',
            'baseUrl': 'https://lrclib.net/api',
            'enabled': true,
            'isBuiltIn': true,
            'kind': 'lrclib',
          },
          {
            'id': 'lyrics-ovh',
            'name': 'lyrics.ovh',
            'baseUrl': 'https://api.lyrics.ovh',
            'enabled': false,
            'isBuiltIn': false,
            'kind': 'lyricsOvh',
          },
        ]);

        final loaded = await storeFor('lyrics_sources.json').load();

        expect(idsOf(loaded), ['lrclib', 'lyrics-ovh']);
        // The user's own toggle survives.
        expect(
          loaded.firstWhere((config) => config.id == 'lyrics-ovh').enabled,
          isFalse,
        );
      },
    );

    test('builtInSources is LRCLIB alone', () {
      expect(idsOf(builtInSources), ['lrclib']);
    });

    test('lyrics.ovh is a non-bundled preset of the right kind', () {
      expect(lyricsOvhPreset.id, 'lyrics-ovh');
      expect(lyricsOvhPreset.isBuiltIn, isFalse);
      expect(lyricsOvhPreset.kind, LyricsSourceKind.lyricsOvh);
    });
  });
}
