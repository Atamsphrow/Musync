// The settings import: what a bundle must look like, what gets written back,
// and how blanked secrets keep the stored keys instead of wiping them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/settings/data/settings_import.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';
import 'package:musync/features/settings/data/ai_secrets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryVault implements AiSecretVault {
  final values = <String, String>{};
  String? failNextWriteFor;

  @override
  Future<String?> read(String id) async => values[id];

  @override
  Future<void> write(String id, String value) async {
    if (failNextWriteFor == id) {
      failNextWriteFor = null;
      throw StateError('Vault unavailable');
    }
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

void main() {
  late Directory root;
  late Directory support;
  late Directory documents;
  late SettingsImporter importer;
  late _MemoryVault vault;

  Future<void> put(Directory dir, String name, String contents) =>
      File('${dir.path}${Platform.pathSeparator}$name').writeAsString(contents);

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
    'files':
        files ??
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
    vault = _MemoryVault();
    importer = SettingsImporter(
      supportDir: support,
      documentsDir: documents,
      aiStore: AiSettingsStore(vault: vault, supportDir: support),
    );
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => root.delete(recursive: true));

  group('parse', () {
    test('accepts a valid bundle', () async {
      final bundle = await importer.parse(await bundleFile(validBundle()));

      expect(bundle.files.keys, [
        'playback_settings.json',
        'lyrics_sources.json',
      ]);
      expect(bundle.preferences, {'bubble_lines': 3});
      expect(bundle.includesSecrets, isFalse);
      expect(bundle.version, '2.15.0');
      expect(bundle.exportedAt, contains('2026-09-30'));
      expect(bundle.ignoredFiles, isEmpty);
    });

    test('rejects a file that is not JSON', () async {
      final file = File('${root.path}/nope.json');
      await file.writeAsString('not json at all');

      expect(() => importer.parse(file), throwsA(isA<ImportFormatException>()));
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
      final file = await bundleFile(
        validBundle(files: {})..remove('preferences'),
      );

      expect(() => importer.parse(file), throwsA(isA<ImportFormatException>()));
    });

    test('accepts a bundle with only preferences', () async {
      // Avant le correctif, le test files.isEmpty rejetait ce bundle avant
      // même de lire les préférences.
      final file = await bundleFile(
        validBundle(files: {})..['preferences'] = {'bubble_lines': 2},
      );

      final bundle = await importer.parse(file);

      expect(bundle.files, isEmpty);
      expect(bundle.preferences, {'bubble_lines': 2});
    });

    test('accepts a bundle with only a tag-backup history', () async {
      final file = await bundleFile(
        validBundle(files: {})
          ..['preferences'] = {}
          ..['tagBackups'] = {
            'index': [
              {
                'filePath': '/music/a.mp3',
                'writtenAt': '2026-09-30T20:00:00.000',
                'tagBytes': 4,
                'writtenMtime': 0,
                'storedAs': 'a-1.tag',
              },
            ],
            'files': {'a-1.tag': base64Encode(utf8.encode('tag!'))},
          },
      );

      final bundle = await importer.parse(file);

      expect(bundle.files, isEmpty);
      expect(bundle.preferences, isEmpty);
      expect(bundle.tagBackups, isNotNull);
      expect(bundle.tagBackups!.entries, hasLength(1));
    });

    test('unreferenced backup bytes are never decoded', () async {
      // Avant le correctif, tout le base64 était décodé avant la validation
      // de l'index : une entrée non référencée corrompue — ou au nom
      // dangereux — rejetait le bundle après avoir alloué ses octets.
      final file = await bundleFile(
        validBundle()
          ..['tagBackups'] = {
            'index': [
              {
                'filePath': '/music/a.mp3',
                'writtenAt': '2026-09-30T20:00:00.000',
                'tagBytes': 4,
                'writtenMtime': 0,
                'storedAs': 'a-1.tag',
              },
            ],
            'files': {
              'a-1.tag': base64Encode(utf8.encode('tag!')),
              'unreferenced.tag': '!!! not base64 !!!',
              '../evil.tag': base64Encode(utf8.encode('x')),
            },
          },
      );

      final bundle = await importer.parse(file);

      expect(bundle.tagBackups!.entries, hasLength(1));
      expect(bundle.tagBackups!.files.keys, ['a-1.tag']);
    });

    test(
      'a referenced backup with corrupt base64 still fails the import',
      () async {
        final file = await bundleFile(
          validBundle()
            ..['tagBackups'] = {
              'index': [
                {
                  'filePath': '/music/a.mp3',
                  'writtenAt': '2026-09-30T20:00:00.000',
                  'tagBytes': 4,
                  'writtenMtime': 0,
                  'storedAs': 'a-1.tag',
                },
              ],
              'files': {'a-1.tag': '!!! not base64 !!!'},
            },
        );

        expect(
          () => importer.parse(file),
          throwsA(isA<ImportFormatException>()),
        );
      },
    );

    test('ignores unknown file names instead of writing them', () async {
      final file = await bundleFile(
        validBundle(
          files: {
            'playback_settings.json': {'lyricsOffsetMs': 40},
            'evil.sh': 'rm -rf /',
          },
        ),
      );

      final bundle = await importer.parse(file);
      expect(bundle.files.keys, ['playback_settings.json']);
      expect(bundle.ignoredFiles, ['evil.sh']);
    });

    test('rejects a lyrics_sources.json that is not a list', () async {
      final bundle = await importer.parse(
        await bundleFile(
          validBundle(
            files: {
              'playback_settings.json': {'lyricsOffsetMs': 40},
              'lyrics_sources.json': {'id': 'lrclib'},
            },
          ),
        ),
      );
      final prefs = await SharedPreferences.getInstance();

      expect(
        () => importer.apply(bundle, prefs),
        throwsA(isA<ImportFormatException>()),
      );
    });

    test('tolerates malformed entries inside lyrics_sources.json', () async {
      // Mirrors LyricsSourceStore.load: bad entries are skipped one by one,
      // only a file that is not a list at all fails the import.
      final bundle = await importer.parse(
        await bundleFile(
          validBundle(
            files: {
              'lyrics_sources.json': [
                {'id': 'lrclib', 'name': 'LRCLIB'},
                'not-a-source',
                {'id': 'broken'},
              ],
            },
          ),
        ),
      );
      final prefs = await SharedPreferences.getInstance();

      final report = await importer.apply(bundle, prefs);
      expect(report.appliedFiles, ['lyrics_sources.json']);
      final written = jsonDecode(
        await File(
          '${documents.path}${Platform.pathSeparator}lyrics_sources.json',
        ).readAsString(),
      );
      expect(written, hasLength(3));
    });

    test('drops invalid preferences', () async {
      for (final bad in [0, 4, '3', 2.5, null]) {
        final bundle = await importer.parse(
          await bundleFile(
            validBundle()..['preferences'] = {'bubble_lines': bad},
          ),
        );
        expect(bundle.preferences, isEmpty, reason: 'bubble_lines=$bad');
      }
    });

    test('accepts the last-played track preferences', () async {
      final bundle = await importer.parse(
        await bundleFile(
          validBundle()
            ..['preferences'] = {
              'bubble_lines': 2,
              'last_song_path': '/storage/music/song.mp3',
              'last_song_position_ms': 83450,
            },
        ),
      );

      expect(bundle.preferences, {
        'bubble_lines': 2,
        'last_song_path': '/storage/music/song.mp3',
        'last_song_position_ms': 83450,
      });
    });

    test('song paths are trimmed, bounded and normalised', () async {
      // Two spellings of the same path must not become two different
      // stored values, and an unbounded string must not land in prefs.
      for (final entry in {
        '  /storage/music/song.mp3  ': '/storage/music/song.mp3',
        '/storage//music///song.mp3': '/storage/music/song.mp3',
        '/storage/music/song.mp3/': '/storage/music/song.mp3',
      }.entries) {
        final parsed = await importer.parse(
          await bundleFile(
            validBundle()..['preferences'] = {'last_song_path': entry.key},
          ),
        );
        expect(
          parsed.preferences['last_song_path'],
          entry.value,
          reason: 'last_song_path=${entry.key}',
        );
      }

      final tooLong = '/${'a' * 5000}';
      final parsed = await importer.parse(
        await bundleFile(
          validBundle()..['preferences'] = {'last_song_path': tooLong},
        ),
      );
      expect(parsed.preferences.containsKey('last_song_path'), isFalse);
    });

    test('a file over 32 Mo is refused on the bytes actually read', () async {
      // Just over the limit; the content is irrelevant, the size check
      // fires first — and it fires on the bytes read, not on a length()
      // taken before the read.
      final file = File('${root.path}${Platform.pathSeparator}big.json');
      await file.writeAsBytes(List<int>.filled(32 * 1024 * 1024 + 1, 0x20));

      await expectLater(
        importer.parse(file),
        throwsA(
          isA<ImportFormatException>().having(
            (e) => e.message,
            'message',
            contains('trop volumineux'),
          ),
        ),
      );
    });

    test('drops invalid last-played track values and unknown keys', () async {
      final bundle = await importer.parse(
        await bundleFile(
          validBundle()
            ..['preferences'] = {
              'last_song_path': '',
              'last_song_position_ms': -1,
              'unknown_key': 'nope',
            },
        ),
      );
      expect(bundle.preferences, isEmpty);

      for (final badPath in [0, 12.5, null]) {
        final parsed = await importer.parse(
          await bundleFile(
            validBundle()..['preferences'] = {'last_song_path': badPath},
          ),
        );
        expect(parsed.preferences, isEmpty, reason: 'last_song_path=$badPath');
      }
      for (final badPos in ['83450', 83.45, null]) {
        final parsed = await importer.parse(
          await bundleFile(
            validBundle()..['preferences'] = {'last_song_position_ms': badPos},
          ),
        );
        expect(
          parsed.preferences,
          isEmpty,
          reason: 'last_song_position_ms=$badPos',
        );
      }
    });
  });

  group('apply', () {
    test('writes each file to its own directory', () async {
      final bundle = await importer.parse(await bundleFile(validBundle()));
      final prefs = await SharedPreferences.getInstance();

      final report = await importer.apply(bundle, prefs);

      final playback = jsonDecode(
        await File(
          '${support.path}${Platform.pathSeparator}playback_settings.json',
        ).readAsString(),
      );
      final sources = jsonDecode(
        await File(
          '${documents.path}${Platform.pathSeparator}lyrics_sources.json',
        ).readAsString(),
      );
      expect(playback, {'lyricsOffsetMs': 40});
      expect(sources, [
        {'id': 'lrclib', 'name': 'LRCLIB'},
      ]);
      expect(report.appliedFiles, [
        'playback_settings.json',
        'lyrics_sources.json',
      ]);
      expect(prefs.getInt('bubble_lines'), 3);
      expect(report.appliedPreferences, ['bubble_lines']);
    });

    test('round-trips the last-played track through parse and apply', () async {
      final bundle = await importer.parse(
        await bundleFile(
          validBundle()
            ..['preferences'] = {
              'bubble_lines': 1,
              'last_song_path': '/storage/music/song.mp3',
              'last_song_position_ms': 83450,
            },
        ),
      );
      final prefs = await SharedPreferences.getInstance();

      final report = await importer.apply(bundle, prefs);

      expect(prefs.getInt('bubble_lines'), 1);
      expect(prefs.getString('last_song_path'), '/storage/music/song.mp3');
      expect(prefs.getInt('last_song_position_ms'), 83450);
      expect(report.appliedPreferences, [
        'bubble_lines',
        'last_song_path',
        'last_song_position_ms',
      ]);
    });

    test(
      'a blank secret keeps the stored key, matched by provider id',
      () async {
        await put(
          support,
          'ai_providers.json',
          jsonEncode({
            'providers': [
              {
                'id': 'p1',
                'name': 'DeepSeek',
                'kind': 'openAiCompatible',
                'apiKey': 'real-key-1',
              },
              {
                'id': 'p2',
                'name': 'OpenAI',
                'kind': 'openAiCompatible',
                'apiKey': 'real-key-2',
              },
            ],
            'instruction': 'old',
          }),
        );
        final bundle = await importer.parse(
          await bundleFile(
            validBundle(
              files: {
                'ai_providers.json': {
                  'providers': [
                    {
                      'id': 'p1',
                      'name': 'DeepSeek renommé',
                      'kind': 'openAiCompatible',
                      'apiKey': '',
                    },
                    {
                      'id': 'p3',
                      'name': 'Nouveau',
                      'kind': 'gemini',
                      'apiKey': '',
                    },
                  ],
                  'instruction': 'new',
                },
              },
            ),
          ),
        );
        final prefs = await SharedPreferences.getInstance();

        final report = await importer.apply(bundle, prefs);

        final written = jsonDecode(
          await File(
            '${support.path}${Platform.pathSeparator}ai_providers.json',
          ).readAsString(),
        ) as Map;
        final providers = written['providers'] as List;
        expect(providers[0]['apiKey'], '');
        expect(vault.values['p1'], 'real-key-1');
        expect(vault.values.containsKey('p2'), isFalse);
        expect(providers[0]['name'], 'DeepSeek renommé');
        // No stored provider p3: the blank stays blank, it is not invented.
        expect(providers[1]['apiKey'], '');
        expect(report.secretsKept, 1);
        expect(report.secretsApplied, 0);
      },
    );

    test(
      'a non-blank secret from the bundle replaces the stored one',
      () async {
        await put(
          support,
          'ai_providers.json',
          jsonEncode({
            'providers': [
              {
                'id': 'p1',
                'name': 'DeepSeek',
                'kind': 'openAiCompatible',
                'apiKey': 'old-key',
              },
            ],
          }),
        );
        final bundle = await importer.parse(
          await bundleFile(
            validBundle(
              files: {
                'ai_providers.json': {
                  'providers': [
                    {
                      'id': 'p1',
                      'name': 'DeepSeek',
                      'kind': 'openAiCompatible',
                      'apiKey': 'new-key',
                    },
                  ],
                },
              },
            ),
          ),
        );
        final prefs = await SharedPreferences.getInstance();

        final report = await importer.apply(bundle, prefs);

        final written = jsonDecode(
          await File(
            '${support.path}${Platform.pathSeparator}ai_providers.json',
          ).readAsString(),
        ) as Map;
        expect((written['providers'] as List).single['apiKey'], '');
        expect(vault.values['p1'], 'new-key');
        expect(report.secretsKept, 0);
        expect(report.secretsApplied, 1);
      },
    );

    Map<String, Object?> aiFile(String key, {String id = 'p1'}) => {
      'providers': [
        {
          'id': id,
          'name': 'Provider',
          'kind': 'openAiCompatible',
          'apiKey': key,
        },
      ],
    };

    test('blank imported key keeps a vault-only key and counts it', () async {
      await put(support, 'ai_providers.json', jsonEncode(aiFile('')));
      vault.values['p1'] = 'VAULT-KEY';
      final bundle = await importer.parse(
        await bundleFile(validBundle(files: {'ai_providers.json': aiFile('')})),
      );
      final report = await importer.apply(
        bundle,
        await SharedPreferences.getInstance(),
      );
      expect(vault.values['p1'], 'VAULT-KEY');
      expect(report.secretsKept, 1);
      expect(report.secretsApplied, 0);
      expect(
        await File('${support.path}/ai_providers.json').readAsString(),
        isNot(contains('VAULT-KEY')),
      );
    });

    test(
      'first import counts its key and stores no plaintext API key',
      () async {
        final bundle = await importer.parse(
          await bundleFile(
            validBundle(files: {'ai_providers.json': aiFile('NEW-SECRET')}),
          ),
        );
        final report = await importer.apply(
          bundle,
          await SharedPreferences.getInstance(),
        );
        expect(vault.values['p1'], 'NEW-SECRET');
        expect(report.secretsApplied, 1);
        expect(
          await File('${support.path}/ai_providers.json').readAsString(),
          isNot(contains('NEW-SECRET')),
        );
      },
    );

    test(
      'partial vault failure restores old keys before any file changes',
      () async {
        final old = jsonEncode(aiFile(''));
        await put(support, 'ai_providers.json', old);
        vault.values['p1'] = 'OLD';
        vault.failNextWriteFor = 'p2';
        final imported = aiFile('NEW');
        (imported['providers'] as List).add(
          (aiFile('SECOND', id: 'p2')['providers'] as List).single,
        );
        final bundle = await importer.parse(
          await bundleFile(
            validBundle(
              files: {
                'ai_providers.json': imported,
                'playback_settings.json': {'lyricsOffsetMs': 99},
              },
            ),
          ),
        );
        final prefs = await SharedPreferences.getInstance();
        await expectLater(importer.apply(bundle, prefs), throwsStateError);
        expect(vault.values, {'p1': 'OLD'});
        expect(
          await File('${support.path}/ai_providers.json').readAsString(),
          old,
        );
        expect(
          await File('${support.path}/playback_settings.json').exists(),
          isFalse,
        );
        expect(prefs.containsKey('bubble_lines'), isFalse);
      },
    );

    test(
      'a later file failure restores keys, metadata and deleted providers',
      () async {
        final old = jsonEncode({
          'providers': [
            ...(aiFile('')['providers'] as List),
            ...(aiFile('', id: 'removed')['providers'] as List),
          ],
        });
        await put(support, 'ai_providers.json', old);
        vault.values.addAll({'p1': 'OLD', 'removed': 'KEEP'});
        await Directory('${documents.path}/lyrics_sources.json').create();
        final bundle = await importer.parse(
          await bundleFile(
            validBundle(
              files: {
                'ai_providers.json': aiFile('NEW'),
                'lyrics_sources.json': <Object?>[],
              },
            ),
          ),
        );
        await expectLater(
          importer.apply(bundle, await SharedPreferences.getInstance()),
          throwsA(isA<ImportFormatException>()),
        );
        expect(vault.values, {'p1': 'OLD', 'removed': 'KEEP'});
        expect(
          await File('${support.path}/ai_providers.json').readAsString(),
          old,
        );
      },
    );

    test('history failure also restores preferences and vault keys', () async {
      final old = jsonEncode(aiFile(''));
      await put(support, 'ai_providers.json', old);
      vault.values['p1'] = 'OLD';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('bubble_lines', 1);
      await Directory('${support.path}/tag_backups/broken.tag')
          .create(recursive: true);
      final bundle = await importer.parse(
        await bundleFile(
          validBundle(files: {'ai_providers.json': aiFile('NEW')})
            ..['tagBackups'] = {
              'index': [
                {
                  'filePath': '/music/test.mp3',
                  'writtenAt': '2026-11-10T10:00:00',
                  'tagBytes': 4,
                  'writtenMtime': 0,
                  'storedAs': 'broken.tag',
                },
              ],
              'files': {
                'broken.tag': base64Encode([1, 2, 3, 4]),
              },
            },
        ),
      );
      await expectLater(
        importer.apply(bundle, prefs),
        throwsA(isA<ImportFormatException>()),
      );
      expect(prefs.getInt('bubble_lines'), 1);
      expect(vault.values, {'p1': 'OLD'});
      expect(
        await File('${support.path}/ai_providers.json').readAsString(),
        old,
      );
    });

    test(
      'duplicate imported provider IDs are rejected before writes',
      () async {
        final imported = aiFile('ONE');
        (imported['providers'] as List).add(
          (aiFile('TWO')['providers'] as List).single,
        );
        final bundle = await importer.parse(
          await bundleFile(validBundle(files: {'ai_providers.json': imported})),
        );
        await expectLater(
          importer.apply(bundle, await SharedPreferences.getInstance()),
          throwsA(isA<ImportFormatException>()),
        );
        expect(vault.values, isEmpty);
        expect(
          await File('${support.path}/ai_providers.json').exists(),
          isFalse,
        );
      },
    );

    test('secrets nested inside a provider are merged too', () async {
      await put(
        support,
        'ai_providers.json',
        jsonEncode({
          'providers': [
            {
              'id': 'p1',
              'name': 'Custom',
              'kind': 'openAiCompatible',
              'auth': {'token': 'stored-token'},
            },
          ],
        }),
      );
      final bundle = await importer.parse(
        await bundleFile(
          validBundle(
            files: {
              'ai_providers.json': {
                'providers': [
                  {
                    'id': 'p1',
                    'name': 'Custom',
                    'kind': 'openAiCompatible',
                    'auth': {'token': ''},
                  },
                ],
              },
            },
          ),
        ),
      );
      final prefs = await SharedPreferences.getInstance();

      final report = await importer.apply(bundle, prefs);

      final written = jsonDecode(
        await File('${support.path}${Platform.pathSeparator}ai_providers.json')
            .readAsString(),
      ) as Map;
      expect(
        (written['providers'] as List).single['auth']['token'],
        'stored-token',
      );
      expect(report.secretsKept, 1);
    });

    test(
      'a failed import never deletes a file whose backup could not be read',
      () async {
        // Double défaillance du finding : la lecture de la sauvegarde
        // échoue (UTF-8 invalide — readAsString lève, même en root), puis
        // une écriture échoue (la cible du 2e fichier est un répertoire, le
        // rename atomique lève). Avant le correctif, le rollback confondait
        // la lecture en échec avec « pas de fichier » et supprimait
        // l'original ; il doit désormais le laisser intact et le dire.
        final playback = File(
          '${support.path}${Platform.pathSeparator}playback_settings.json',
        );
        await playback.writeAsBytes([0xFF, 0xFE, 0x41]);
        await Directory(
          '${documents.path}${Platform.pathSeparator}lyrics_sources.json',
        ).create();
        final bundle = await importer.parse(await bundleFile(validBundle()));
        final prefs = await SharedPreferences.getInstance();

        await expectLater(
          importer.apply(bundle, prefs),
          throwsA(
            isA<ImportFormatException>().having(
              (e) => e.message,
              'message',
              contains('sauvegarde illisible'),
            ),
          ),
        );

        expect(await playback.exists(), isTrue);
        // Le rollback n'a pas pu restaurer l'ancien contenu (illisible) :
        // le fichier garde le contenu importé — il n'a pas été supprimé.
        expect(jsonDecode(await playback.readAsString()), {
          'lyricsOffsetMs': 40,
        });
      },
    );

    test(
      'a failed history import never deletes an index it could not read',
      () async {
        // Site frère de G79, dans `_applyTagBackups` : la lecture de
        // l'index échoue (UTF-8 invalide — readAsString lève, même en
        // root ; un répertoire ne suffirait pas, `File.exists()` rend
        // faux pour un répertoire), puis une écriture échoue (la cible
        // est un répertoire, le rename atomique lève). Avant le
        // correctif, le rollback confondait la lecture en échec avec
        // « pas de fichier » et supprimait l'index ; il doit désormais
        // le laisser intact et le dire.
        final tagBackups = Directory(
          '${support.path}${Platform.pathSeparator}tag_backups',
        );
        await tagBackups.create();
        final index = File(
          '${tagBackups.path}${Platform.pathSeparator}index.json',
        );
        await index.writeAsBytes([0xFF, 0xFE, 0x41]);
        await Directory('${tagBackups.path}${Platform.pathSeparator}a-1.tag')
            .create();
        final bundle = await importer.parse(
          await bundleFile(
            validBundle(files: {})
              ..['preferences'] = {}
              ..['tagBackups'] = {
                'index': [
                  {
                    'filePath': '/music/a.mp3',
                    'writtenAt': '2026-09-30T20:00:00.000',
                    'tagBytes': 4,
                    'writtenMtime': 0,
                    'storedAs': 'a-1.tag',
                  },
                ],
                'files': {'a-1.tag': base64Encode(utf8.encode('tag!'))},
              },
          ),
        );
        final prefs = await SharedPreferences.getInstance();

        await expectLater(
          importer.apply(bundle, prefs),
          throwsA(
            isA<ImportFormatException>().having(
              (e) => e.message,
              'message',
              contains('pas pu être entièrement restauré'),
            ),
          ),
        );

        expect(await index.exists(), isTrue);
        // L'index illisible est intact, octet pour octet.
        expect(await index.readAsBytes(), [0xFF, 0xFE, 0x41]);
      },
    );
  });
}
