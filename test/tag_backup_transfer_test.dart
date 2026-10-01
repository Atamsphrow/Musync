// The tag-backup history transfer: export writes the index plus every
// referenced backup, import validates and restores them atomically.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/settings/data/settings_export.dart';
import 'package:musync/features/settings/data/settings_import.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;
  late Directory support;
  late Directory documents;
  late Directory backups;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('musync_history_');
    support = await Directory('${root.path}/support').create();
    documents = await Directory('${root.path}/documents').create();
    backups = await Directory('${support.path}/tag_backups').create();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> seedBackups() async {
    await File('${backups.path}/index.json').writeAsString(
      jsonEncode([
        {
          'filePath': '/music/a.mp3',
          'writtenAt': '2026-09-30T20:00:00.000',
          'tagBytes': 4,
          'writtenMtime': 123,
          'storedAs': 'a-1.tag',
        },
        {
          'filePath': '/music/b.mp3',
          'writtenAt': '2026-09-30T21:00:00.000',
          'tagBytes': 4,
          'writtenMtime': 456,
          'storedAs': 'b-1.tag',
        },
      ]),
    );
    await File('${backups.path}/a-1.tag').writeAsBytes([1, 2, 3, 4]);
    await File('${backups.path}/b-1.tag').writeAsBytes([5, 6, 7, 8]);
  }

  Map<String, Object?> bundleWith(Object? tagBackups) => {
    'app': 'Musync',
    'version': '2.15.0',
    'exportedAt': '2026-09-30T20:00:00.000',
    'includesSecrets': false,
    'files': {
      'playback_settings.json': {'x': 1},
    },
    'preferences': {},
    'tagBackups': tagBackups,
  };

  Future<ImportBundle> parseBundle(Map<String, Object?> bundle) async {
    final file = File('${root.path}/bundle.json');
    await file.writeAsString(jsonEncode(bundle));
    return SettingsImporter(supportDir: support, documentsDir: documents)
        .parse(file);
  }

  group('export', () {
    test('round-trip: index and bytes survive', () async {
      await seedBackups();
      final exporter = SettingsExporter(
        supportDir: support,
        documentsDir: documents,
      );
      final built = await exporter.build();
      final section = built['tagBackups'] as Map;

      expect((section['index'] as List).length, 2);
      expect((section['files'] as Map).length, 2);
      expect(
        base64Decode((section['files'] as Map)['a-1.tag'] as String),
        [1, 2, 3, 4],
      );

      // And the import puts them back byte for byte.
      final parsed = await parseBundle(
        bundleWith(jsonDecode(jsonEncode(section))),
      );
      final report = await SettingsImporter(
        supportDir: support,
        documentsDir: documents,
      ).apply(parsed, await SharedPreferences.getInstance());

      expect(report.tagBackupsRestored, 2);
      expect(report.tagBackupsSkipped, isEmpty);
      expect(await File('${backups.path}/a-1.tag').readAsBytes(), [1, 2, 3, 4]);
      expect(await File('${backups.path}/b-1.tag').readAsBytes(), [5, 6, 7, 8]);
      final index = jsonDecode(
        await File('${backups.path}/index.json').readAsString(),
      ) as List;
      expect(index.length, 2);
    });

    test('missing backup file is reported, not fatal', () async {
      await seedBackups();
      await File('${backups.path}/b-1.tag').delete();

      final built = await SettingsExporter(
        supportDir: support,
        documentsDir: documents,
      ).build();
      final section = built['tagBackups'] as Map;

      expect((section['index'] as List).length, 2);
      expect((section['files'] as Map).length, 1);
      expect(section['missing'], ['b-1.tag']);

      // Import restores what it has and reports the skip.
      final parsed = await parseBundle(
        bundleWith(jsonDecode(jsonEncode(section))),
      );
      expect(parsed.tagBackups!.skipped, ['b-1.tag']);
      final report = await SettingsImporter(
        supportDir: support,
        documentsDir: documents,
      ).apply(parsed, await SharedPreferences.getInstance());

      expect(report.tagBackupsRestored, 1);
      expect(report.tagBackupsSkipped, ['b-1.tag']);
      // The restored index holds no dangling reference.
      final index = jsonDecode(
        await File('${backups.path}/index.json').readAsString(),
      ) as List;
      expect(index.length, 1);
      expect(index.first['storedAs'], 'a-1.tag');
    });

    test('no history on the phone: empty section', () async {
      final built = await SettingsExporter(
        supportDir: support,
        documentsDir: documents,
      ).build();
      final section = built['tagBackups'] as Map;

      expect(section['index'], isEmpty);
      expect(section['files'], isEmpty);

      final parsed = await parseBundle(
        bundleWith(jsonDecode(jsonEncode(section))),
      );
      expect(parsed.tagBackups, isNotNull);
      expect(parsed.tagBackups!.isEmpty, isTrue);
      final report = await SettingsImporter(
        supportDir: support,
        documentsDir: documents,
      ).apply(parsed, await SharedPreferences.getInstance());
      expect(report.tagBackupsRestored, 0);
    });
  });

  group('import validation', () {
    test('corrupt base64 fails the import', () async {
      await expectLater(
        parseBundle(bundleWith({
          'index': [
            {
              'filePath': '/music/a.mp3',
              'writtenAt': '2026-09-30T20:00:00.000',
              'tagBytes': 4,
              'writtenMtime': 123,
              'storedAs': 'a-1.tag',
            },
          ],
          'files': {'a-1.tag': '!!!pas-du-base64!!!'},
        })),
        throwsA(isA<ImportFormatException>()),
      );
    });

    test('path traversal in storedAs fails the import', () async {
      final evil = base64Encode(Uint8List.fromList([1]));
      await expectLater(
        parseBundle(bundleWith({
          'index': [
            {
              'filePath': '/music/a.mp3',
              'writtenAt': '2026-09-30T20:00:00.000',
              'tagBytes': 4,
              'writtenMtime': 123,
              'storedAs': '../../evil.tag',
            },
          ],
          'files': {'../../evil.tag': evil},
        })),
        throwsA(isA<ImportFormatException>()),
      );
      expect(
        await File('${root.path}/evil.tag').exists(),
        isFalse,
        reason: 'nothing may be written outside tag_backups',
      );
    });

    test('malformed section fails the import', () async {
      await expectLater(
        parseBundle(bundleWith({'index': 'pas-une-liste', 'files': {}})),
        throwsA(isA<ImportFormatException>()),
      );
      await expectLater(
        parseBundle(bundleWith('pas-un-objet')),
        throwsA(isA<ImportFormatException>()),
      );
    });

    test('no tagBackups section: history untouched', () async {
      await seedBackups();
      final parsed = await parseBundle({
        'app': 'Musync',
        'version': '2.15.0',
        'exportedAt': '2026-09-30T20:00:00.000',
        'includesSecrets': false,
        'files': {
          'playback_settings.json': {'x': 1},
        },
        'preferences': {},
      });
      expect(parsed.tagBackups, isNull);

      final report = await SettingsImporter(
        supportDir: support,
        documentsDir: documents,
      ).apply(parsed, await SharedPreferences.getInstance());
      expect(report.tagBackupsRestored, 0);
      // The phone's history survived.
      expect(await File('${backups.path}/a-1.tag').exists(), isTrue);
      expect((jsonDecode(await File('${backups.path}/index.json')
              .readAsString()) as List)
          .length, 2);
    });

    test('isSafeBackupName', () {
      expect(isSafeBackupName('a-1.tag'), isTrue);
      expect(isSafeBackupName('2026.bak'), isTrue);
      expect(isSafeBackupName(''), isFalse);
      expect(isSafeBackupName('../x'), isFalse);
      expect(isSafeBackupName('a/b'), isFalse);
      expect(isSafeBackupName('a b'), isFalse);
      expect(isSafeBackupName('.hidden'), isFalse);
    });
  });
}
