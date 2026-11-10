/// A keystore/keychain-backed vault for AI provider credentials.
///
/// A narrow interface keeps the migration and its failure handling testable
/// without an Android/iOS plugin in the test process.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class AiSecretVault {
  Future<String?> read(String id);
  Future<void> write(String id, String value);
  Future<void> delete(String id);
}

class PlatformAiSecretVault implements AiSecretVault {
  const PlatformAiSecretVault();

  // Never silently erase credentials after a platform decryption error.
  // Keep encrypted backups while upgrading the plugin's cipher format.
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false, migrateWithBackup: true),
  );
  static const _prefix = 'musync.ai.api_key.';

  @override
  Future<String?> read(String id) => _storage.read(key: '$_prefix$id');

  @override
  Future<void> write(String id, String value) =>
      _storage.write(key: '$_prefix$id', value: value);

  @override
  Future<void> delete(String id) => _storage.delete(key: '$_prefix$id');
}
