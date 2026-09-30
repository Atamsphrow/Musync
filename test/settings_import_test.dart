// The settings import: what a bundle must look like, what gets written back,
// and how blanked secrets keep the stored keys instead of wiping them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/settings/data/settings_import.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;
  late Directory support;
  late Directory documents;
  late SettingsImporter importer;

  Future<void> put(Directory dir, String name, String contents) =>
      File('${dir.path}${Platform.pathSeparator}$name')
          .writeAsString(contents);

  Future<File> bundleFile(Map<String, Object?> bundle) async {
    final file = File('${root.path}${Platform.pathSeparator}bundle.json');
    await file.writeAsString(jsonEncode(bundle));
    return file;
  }

  Map<String, Object?> validBundle({Map<String, Object?>? files}) => {
        'app': 'Musync',
        'version': '2.15.0',
        'exportedAt': '2026-09-30T20:00:00.000',
        'includesSecrets': false,
        'files': files ??
            {
              'playback_settings.json': {'lyricsOffsetMs': 40},
              'lyrics_sources.json': [
                {'id': 'lrclib', 'name': 'LRCLIB'},
              ],
            },
        'preferences': {'bubble_lines': 3},
      };

  setUp(() async {
    root = await Directory.systemTemp.createTemp('musync_import_');
    support = await Directory('${root.path}/support').create();
    documents = await Directory('${root.path}/documents').create();
    importer = SettingsImporter(supportDir: support, documentsDir: documents);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => root.delete(recursive: true));

  group('parse', () {
    test('accepts a valid bundle', () async {
      final bundle = await importer.parse(await bundleFile(validBundle()));

      expect(bundle.files.keys,
          ['playback_settings.json', 'lyrics_sources.json']);
      expect(bundle.preferences, {'bubble_lines': 3});
      expect(bundle.includesSecrets, isFalse);
      expect(bundle.version, '2.15.0');
      expect(bundle.exportedAt, contains('2026-09-30'));
      expect(bundle.ignoredFiles, isEmpty);
    });

    test('rejects a file that is not JSON', () async {
      final file = File('${root.path}/nope.json');
      await file.writeAsString('not json at all');

      expect(
        () => importer.parse(file),
        throwsA(isA<ImportFormatException>()),
      );
    });

    test('rejects a JSON file that is not a Musync export', () async {
      final file = await bundleFile({'app': 'Musicolet', 'files': {}});

      await expectLater(
        importer.parse(file),
        throwsA(
          isA<ImportFormatException>().having(
            (e) => e.message,
            'message',
            contains('Musync'),
          ),
        ),
      );
    });

    test('rejects a bundle with no known settings file', () async {
      final file = await bundleFile(validBundle(files: {}));

      expect(
        () => importer.parse(file),
        throwsA(isA<ImportFormatException>()),
      );
    });

    test('ignores unknown file names instead of writing them', () async {
      final file = await bundleFile(validBundle(files: {
        'playback_settings.json': {'lyricsOffsetMs': 40},
        'evil.sh': 'rm -rf /',
      }));

      final bundle = await importer.parse(file);
      expect(bundle.files.keys, ['playback_settings.json']);
      expect(bundle.ignoredFiles, ['evil.sh']);
    });

    test('drops invalid preferences', () async {
      for (final bad in [0, 4, '3', 2.5, null]) {
        final bundle = await importer.parse(
          await bundleFile(validBundle()
            ..['preferences'] = {'bubble_lines': bad}),
        );
        expect(bundle.preferences, isEmpty, reason: 'bubble_lines=$bad');
      }
    });
  });

  group('apply', () {
    test('writes each file to its own directory', () async {
      final bundle = await importer.parse(await bundleFile(validBundle()));
      final prefs = await SharedPreferences.getInstance();

      final report = await importer.apply(bundle, prefs);

      final playback = jsonDecode(await File(
              '${support.path}${Platform.pathSeparator}playback_settings.json')
          .readAsString());
      final sources = jsonDecode(await File(
              '${documents.path}${Platform.pathSeparator}lyrics_sources.json')
          .readAsString());
      expect(playback, {'lyricsOffsetMs': 40});
      expect(sources, [
        {'id': 'lrclib', 'name': 'LRCLIB'}
      ]);
      expect(report.appliedFiles,
          ['playback_settings.json', 'lyrics_sources.json']);
      expect(prefs.getInt('bubble_lines'), 3);
      expect(report.appliedPreferences, ['bubble_lines']);
    });

    test('a blank secret keeps the stored key, matched by provider id',
        () async {
      await put(support, 'ai_providers.json', jsonEncode({
        'providers': [
          {'id': 'p1', 'name': 'DeepSeek', 'apiKey': 'real-key-1'},
          {'id': 'p2', 'name': 'OpenAI', 'apiKey': 'real-key-2'},
        ],
        'instruction': 'old',
      }));
      final bundle = await importer.parse(await bundleFile(validBundle(files: {
        'ai_providers.json': {
          'providers': [
            {'id': 'p1', 'name': 'DeepSeek renommé', 'apiKey': ''},
            {'id': 'p3', 'name': 'Nouveau', 'apiKey': ''},
          ],
          'instruction': 'new',
        },
      })));
      final prefs = await SharedPreferences.getInstance();

      final report = await importer.apply(bundle, prefs);

      final written = jsonDecode(await File(
              '${support.path}${Platform.pathSeparator}ai_providers.json')
          .readAsString()) as Map;
      final providers = written['providers'] as List;
      expect(providers[0]['apiKey'], 'real-key-1');
      expect(providers[0]['name'], 'DeepSeek renommé');
      // No stored provider p3: the blank stays blank, it is not invented.
      expect(providers[1]['apiKey'], '');
      expect(report.secretsKept, 1);
      expect(report.secretsApplied, 0);
    });

    test('a non-blank secret from the bundle replaces the stored one',
        () async {
      await put(support, 'ai_providers.json', jsonEncode({
        'providers': [
          {'id': 'p1', 'name': 'DeepSeek', 'apiKey': 'old-key'},
        ],
      }));
      final bundle = await importer.parse(await bundleFile(validBundle(files: {
        'ai_providers.json': {
          'providers': [
            {'id': 'p1', 'name': 'DeepSeek', 'apiKey': 'new-key'},
          ],
        },
      })));
      final prefs = await SharedPreferences.getInstance();

      final report = await importer.apply(bundle, prefs);

      final written = jsonDecode(await File(
              '${support.path}${Platform.pathSeparator}ai_providers.json')
          .readAsString()) as Map;
      expect((written['providers'] as List).single['apiKey'], 'new-key');
      expect(report.secretsKept, 0);
      expect(report.secretsApplied, 1);
    });

    test('secrets nested inside a provider are merged too', () async {
      await put(support, 'ai_providers.json', jsonEncode({
        'providers': [
          {
            'id': 'p1',
            'name': 'Custom',
            'auth': {'token': 'stored-token'}
          },
        ],
      }));
      final bundle = await importer.parse(await bundleFile(validBundle(files: {
        'ai_providers.json': {
          'providers': [
            {
              'id': 'p1',
              'name': 'Custom',
              'auth': {'token': ''}
            },
          ],
        },
      })));
      final prefs = await SharedPreferences.getInstance();

      final report = await importer.apply(bundle, prefs);

      final written = jsonDecode(await File(
              '${support.path}${Platform.pathSeparator}ai_providers.json')
          .readAsString()) as Map;
      expect((written['providers'] as List).single['auth']['token'],
          'stored-token');
      expect(report.secretsKept, 1);
    });
  });
}
