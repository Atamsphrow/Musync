import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';
import 'package:musync/features/settings/data/ai_secrets.dart';

class _MemoryVault implements AiSecretVault {
  final values = <String, String>{};
  bool failWrites = false;
  Future<void> Function()? beforeWrite;

  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    if (failWrites) throw StateError('Secure store unavailable');
    await beforeWrite?.call();
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async => values.remove(id);
}

AiProviderConfig provider(String id, String key) => AiProviderConfig(
  id: id,
  name: 'Test',
  kind: AiProviderKind.openAiCompatible,
  baseUrl: 'https://example.invalid/v1',
  model: 'model',
  apiKey: key,
);

void main() {
  late Directory dir;
  late _MemoryVault vault;
  late AiSettingsStore store;
  late File jsonFile;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('musync-secure-test-');
    vault = _MemoryVault();
    store = AiSettingsStore(vault: vault, supportDir: dir);
    jsonFile = File('${dir.path}/ai_providers.json');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('migrates legacy plaintext and scrubs the file', () async {
    await jsonFile.writeAsString(
      jsonEncode({
        'providers': [provider('first', 'LEGACY-SECRET').toJson()],
        'instruction': 'Reste strict.',
      }),
    );
    final loaded = await store.load();
    expect(loaded.providers.single.apiKey, 'LEGACY-SECRET');
    expect(vault.values['first'], 'LEGACY-SECRET');
    expect(await jsonFile.readAsString(), isNot(contains('LEGACY-SECRET')));
    expect(loaded.instruction, 'Reste strict.');
  });

  test('failed vault migration does not erase existing plaintext', () async {
    await jsonFile.writeAsString(
      jsonEncode({
        'providers': [provider('first', 'LEGACY-SECRET').toJson()],
      }),
    );
    vault.failWrites = true;
    await expectLater(store.load(), throwsStateError);
    expect(await jsonFile.readAsString(), contains('LEGACY-SECRET'));
  });

  test('normal save does not put credentials back into JSON', () async {
    await store.save(AiSettings(providers: [provider('first', 'NEW-SECRET')]));
    expect(vault.values['first'], 'NEW-SECRET');
    expect(await jsonFile.readAsString(), isNot(contains('NEW-SECRET')));
    expect((await store.load()).providers.single.apiKey, 'NEW-SECRET');
  });

  test(
    'confirmed import overrides old vault key, ordinary load does not',
    () async {
      vault.values['first'] = 'CURRENT';
      await jsonFile.writeAsString(
        jsonEncode({
          'providers': [provider('first', 'IMPORTED').toJson()],
        }),
      );
      expect((await store.load()).providers.single.apiKey, 'CURRENT');
      await jsonFile.writeAsString(
        jsonEncode({
          'providers': [provider('first', 'IMPORTED').toJson()],
        }),
      );
      expect((await store.loadImported()).providers.single.apiKey, 'IMPORTED');
      expect(vault.values['first'], 'IMPORTED');
    },
  );

  test(
    'separate store instances serialize the entire vault/file save',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var writes = 0;
      vault.beforeWrite = () async {
        if (++writes == 1) {
          entered.complete();
          await release.future;
        }
      };
      final second = AiSettingsStore(vault: vault, supportDir: dir);
      final firstSave = store.save(
        AiSettings(providers: [provider('first', 'ONE')]),
      );
      await entered.future;
      final secondSave = second.save(
        AiSettings(providers: [provider('second', 'TWO')]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(writes, 1);
      release.complete();
      await Future.wait([firstSave, secondSave]);
      expect(vault.values, {'second': 'TWO'});
      final loaded = await store.load();
      expect(loaded.providers.single.id, 'second');
      expect(loaded.providers.single.apiKey, 'TWO');
    },
  );

  test(
    'invalid metadata cannot be silently replaced by an empty store',
    () async {
      await jsonFile.writeAsString('{"providers":"broken"}');
      vault.values['first'] = 'KEEP';
      await expectLater(store.save(const AiSettings()), throwsFormatException);
      expect(await jsonFile.readAsString(), '{"providers":"broken"}');
      expect(vault.values['first'], 'KEEP');
    },
  );

  test('delete a provider cleans its key from keystore', () async {
    await store.save(AiSettings(providers: [provider('first', 'SECRET')]));
    await store.save(const AiSettings());
    expect(vault.values.containsKey('first'), false);
  });
}
