// The settings export: what goes in, what is blanked, and what does not stop it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/settings/data/settings_export.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';

void main() {
  late Directory root;
  late Directory support;
  late Directory documents;
  late SettingsExporter exporter;

  Future<void> put(Directory dir, String name, String contents) =>
      File('${dir.path}${Platform.pathSeparator}$name').writeAsString(contents);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('musync_export_');
    support = await Directory('${root.path}/support').create();
    documents = await Directory('${root.path}/documents').create();
    exporter = SettingsExporter(supportDir: support, documentsDir: documents);
  });

  tearDown(() => root.delete(recursive: true));

  test('carries each settings file under its own name', () async {
    await put(support, 'playback_settings.json', '{"lyricsOffsetMs": 40}');
    await put(documents, 'lyrics_sources.json', '[{"name":"LRCLIB"}]');

    final bundle = await exporter.build();
    final files = bundle['files'] as Map;

    expect(files['playback_settings.json'], {'lyricsOffsetMs': 40});
    expect(files['lyrics_sources.json'], [
      {'name': 'LRCLIB'},
    ]);
    expect(bundle['app'], 'Musync');
    expect(bundle['version'], isNotEmpty);
  });

  test('a file that is not there is left out, not an error', () async {
    final bundle = await exporter.build();
    expect(bundle['files'], isEmpty);
    expect(bundle.containsKey('unreadable'), isFalse);
  });

  test('a corrupt file is reported and the rest still exports', () async {
    await put(support, 'playback_settings.json', '{not json');
    await put(support, 'ai_providers.json', '{"active": "gemini"}');

    final bundle = await exporter.build();

    expect(bundle['unreadable'], ['playback_settings.json']);
    expect((bundle['files'] as Map).keys, ['ai_providers.json']);
  });

  group('secrets', () {
    const providers =
        '{"providers":[{"name":"Gemini","apiKey":"SECRET-1","model":"m"},'
        '{"name":"Groq","apiKey":"","model":"n"}],'
        '"custom":{"Authorization":"Bearer SECRET-2","url":"https://x"}}';

    test('are blanked by default, wherever they sit', () async {
      await put(support, 'ai_providers.json', providers);

      final bundle = await exporter.build();
      final text = jsonEncode(bundle);

      expect(text.contains('SECRET-1'), isFalse);
      expect(text.contains('SECRET-2'), isFalse);
      expect(bundle['includesSecrets'], isFalse);
    });

    test('blanking keeps the shape and the harmless fields', () async {
      await put(support, 'ai_providers.json', providers);

      final files = (await exporter.build())['files'] as Map;
      final ai = files['ai_providers.json'] as Map;
      final first = (ai['providers'] as List).first as Map;

      expect(first['apiKey'], kExportRedacted);
      expect(first['name'], 'Gemini');
      expect(first['model'], 'm');
      expect((ai['custom'] as Map)['url'], 'https://x');
    });

    test('are kept when the user asks for them', () async {
      await put(support, 'ai_providers.json', providers);

      final bundle = await exporter.build(includeSecrets: true);

      expect(jsonEncode(bundle).contains('SECRET-1'), isTrue);
      expect(bundle['includesSecrets'], isTrue);
    });

    test('secure vault keys export only after explicit opt-in', () async {
      await put(
        support,
        'ai_providers.json',
        jsonEncode({
          'providers': [
            {'id': 'p1', 'name': 'Gemini', 'apiKey': ''},
          ],
        }),
      );
      final configured = AiSettings(
        providers: [
          const AiProviderConfig(
            id: 'p1',
            name: 'Gemini',
            kind: AiProviderKind.gemini,
            baseUrl: 'https://example.test',
            model: 'model',
            apiKey: 'VAULT-ONLY-KEY',
          ),
        ],
      );
      final safe = await exporter.build(aiSettings: configured);
      expect(jsonEncode(safe), isNot(contains('VAULT-ONLY-KEY')));
      final portable = await exporter.build(
        includeSecrets: true,
        aiSettings: configured,
      );
      expect(jsonEncode(portable), contains('VAULT-ONLY-KEY'));
    });

    test('a field only looks like a secret if it is a string', () {
      // "tokens" the number of tokens used, say, is not a credential.
      final out = SettingsExporter.redact({'maxTokens': 512, 'apiKey': 'k'});
      expect(out, {'maxTokens': 512, 'apiKey': kExportRedacted});
    });
  });

  test('exportTo writes a timestamped file that reads back', () async {
    await put(support, 'playback_settings.json', '{"a": 1}');
    final out = Directory('${root.path}/out/Musync');

    final file = await exporter.exportTo(
      out,
      preferences: {'bubble_lines': 3},
      now: DateTime(2026, 9, 30, 8, 5, 9),
    );

    expect(file.path.endsWith('musync-export-20260930-080509.json'), isTrue);
    final back = jsonDecode(await file.readAsString()) as Map;
    expect(back['preferences'], {'bubble_lines': 3});
    expect((back['files'] as Map)['playback_settings.json'], {'a': 1});
  });

  test('exportTo forwards vault keys only with explicit opt-in', () async {
    await put(
      support,
      'ai_providers.json',
      jsonEncode({
        'providers': [
          {'id': 'p1', 'apiKey': ''},
        ],
      }),
    );
    const configured = AiSettings(
      providers: [
        AiProviderConfig(
          id: 'p1',
          name: 'Test',
          kind: AiProviderKind.gemini,
          baseUrl: 'https://example.invalid',
          model: 'model',
          apiKey: 'VAULT-KEY',
        ),
      ],
    );
    final out = Directory('${root.path}/out');
    final safe = await exporter.exportTo(
      out,
      aiSettings: configured,
      now: DateTime(2026, 11, 10, 1),
    );
    expect(await safe.readAsString(), isNot(contains('VAULT-KEY')));
    final portable = await exporter.exportTo(
      out,
      aiSettings: configured,
      includeSecrets: true,
      now: DateTime(2026, 11, 10, 2),
    );
    expect(await portable.readAsString(), contains('VAULT-KEY'));
  });

  test('two exports never replace each other', () async {
    final out = Directory('${root.path}/out');
    final a = await exporter.exportTo(out, now: DateTime(2026, 1, 1, 10));
    final b = await exporter.exportTo(out, now: DateTime(2026, 1, 1, 11));
    expect(a.path, isNot(b.path));
    expect(out.listSync(), hasLength(2));
  });

  group('tag backups', () {
    test('a symlinked backup is not followed out of its directory', () async {
      // The backup index is the app's own file, but a planted symlink
      // inside tag_backups/ would otherwise be read and base64-encoded
      // into the export, wherever it points.
      final dir = Directory('${support.path}/tag_backups')..createSync();
      final target = File('${root.path}/outside.bin')
        ..writeAsStringSync('secret-bytes');
      final link = Link('${dir.path}/backup1.bin');
      await link.create(target.path);

      const entry = {
        'filePath': '/music/song.mp3',
        'writtenAt': '2026-09-30T08:00:00.000',
        'tagBytes': 11,
        'writtenMtime': 1,
        'storedAs': 'backup1.bin',
      };
      await put(dir, 'index.json', jsonEncode([entry]));

      final bundle = await exporter.build();
      final backups = bundle['tagBackups'] as Map;

      expect((backups['files'] as Map).containsKey('backup1.bin'), isFalse);
      expect(backups['unreadable'], contains('backup1.bin'));
      expect(jsonEncode(bundle), isNot(contains('secret-bytes')));
    });
  });

  test('exportTo fails loudly on a value JSON cannot encode', () async {
    // Preferences travel as-is into the bundle: an unencodable value must
    // fail here with a message that says so, not as a bare
    // JsonUnsupportedObjectError from inside the encoder.
    await expectLater(
      exporter.exportTo(
        Directory('${root.path}/out'),
        preferences: {'when': DateTime(2026, 1, 1)},
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('JSON')),
      ),
    );
  });
}
