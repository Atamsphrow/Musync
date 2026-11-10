/// Language models the user has configured, and the instruction they are given.
///
/// Musync uses one for exactly one job: reading an artist and a title out of a
/// file name whose tags are wrong. A local heuristic already handles the
/// regular shapes; a model earns its place on the awkward ones — a name with no
/// separator, or one where the title comes before the artist.
///
/// Nothing here is required. With no provider configured the button falls back
/// to the heuristic, which is why none of this ships with a key.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:musync/features/settings/data/ai_secrets.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

/// Which API shape a provider speaks.
enum AiProviderKind {
  /// Google's `generativelanguage.googleapis.com`.
  gemini,

  /// Anything with OpenAI's `/chat/completions` — OpenAI itself, Groq,
  /// OpenRouter, Mistral, or a model served locally. One implementation, a
  /// great many providers.
  openAiCompatible,
}

@immutable
class AiProviderConfig {
  final String id;
  final String name;
  final AiProviderKind kind;

  /// API root, without a trailing slash.
  final String baseUrl;

  /// Model identifier, as that provider spells it.
  final String model;

  /// Only held in memory. At rest the key lives in the platform
  /// keystore/keychain, not in ai_providers.json; see [AiSettingsStore].
  final String apiKey;

  final bool enabled;

  const AiProviderConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    this.enabled = true,
  });

  /// Usable only once there is something to authenticate with.
  bool get isUsable => enabled && apiKey.trim().isNotEmpty;

  /// What may be shown or written down: enough to recognise a key, never
  /// enough to use it.
  String get redactedKey {
    final key = apiKey.trim();
    if (key.isEmpty) return '(aucune clé)';
    if (key.length <= 8) return '••••';
    return '••••${key.substring(key.length - 4)}';
  }

  AiProviderConfig copyWith({
    String? name,
    AiProviderKind? kind,
    String? baseUrl,
    String? model,
    String? apiKey,
    bool? enabled,
  }) => AiProviderConfig(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': apiKey,
    'enabled': enabled,
  };

  static AiProviderConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty || name is! String) return null;

    final kind = AiProviderKind.values
        .where((k) => k.name == raw['kind'])
        .firstOrNull;
    if (kind == null) return null;

    return AiProviderConfig(
      id: id,
      name: name,
      kind: kind,
      baseUrl: raw['baseUrl'] is String
          ? raw['baseUrl'] as String
          : defaultBaseUrlFor(kind),
      model: raw['model'] is String
          ? raw['model'] as String
          : defaultModelFor(kind),
      apiKey: raw['apiKey'] is String ? raw['apiKey'] as String : '',
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiProviderConfig &&
          other.id == id &&
          other.name == name &&
          other.kind == kind &&
          other.baseUrl == baseUrl &&
          other.model == model &&
          other.apiKey == apiKey &&
          other.enabled == enabled;

  @override
  int get hashCode =>
      Object.hash(id, name, kind, baseUrl, model, apiKey, enabled);

  /// Never the key. This is what ends up in a log line or an error message.
  @override
  String toString() => 'AiProviderConfig($name, ${kind.name}, $redactedKey)';
}

String defaultBaseUrlFor(AiProviderKind kind) => switch (kind) {
  AiProviderKind.gemini => 'https://generativelanguage.googleapis.com/v1beta',
  AiProviderKind.openAiCompatible => 'https://api.openai.com/v1',
};

/// A common provider that speaks the OpenAI shape.
///
/// Picked from a list rather than typed in. The form shows the address it ships
/// with — and that address is the source of truth, not a starting point. Setting
/// it to "use my own" is what the form's free-text field is for.
@immutable
class OpenAiCompatiblePreset {
  final String name;

  /// Base URL the user gets when they pick this entry, with the trailing slash
  /// stripped.
  final String baseUrl;

  const OpenAiCompatiblePreset({required this.name, required this.baseUrl});
}

const List<OpenAiCompatiblePreset> openAiCompatiblePresets = [
  OpenAiCompatiblePreset(name: 'OpenAI', baseUrl: 'https://api.openai.com/v1'),
  OpenAiCompatiblePreset(
    name: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
  ),
  OpenAiCompatiblePreset(
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
  ),
  OpenAiCompatiblePreset(name: 'Mistral', baseUrl: 'https://api.mistral.ai/v1'),
  OpenAiCompatiblePreset(
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
  ),
  OpenAiCompatiblePreset(
    name: 'LM Studio (local)',
    baseUrl: 'http://localhost:1234/v1',
  ),
  OpenAiCompatiblePreset(
    name: 'Ollama (local)',
    baseUrl: 'http://localhost:11434/v1',
  ),
];

/// The default is a guess with a short shelf life, which is why it is checked.
///
/// `gemini-2.0-flash` sat here until Google retired it, and the only symptom was
/// a 404 at the moment of use — a default that has quietly expired is worse than
/// no default, because it looks configured. The name below is taken from the
/// test report, not from any guarantee: `AiFilenameReader.checkModel` asks the
/// provider directly and the Settings tab shows the answer, so a stale default
/// is now visible before it is used rather than after.
String defaultModelFor(AiProviderKind kind) => switch (kind) {
  AiProviderKind.gemini => 'gemini-3.6-flash',
  AiProviderKind.openAiCompatible => 'gpt-4o-mini',
};

String labelFor(AiProviderKind kind) => switch (kind) {
  AiProviderKind.gemini => 'Google Gemini',
  AiProviderKind.openAiCompatible => 'Compatible OpenAI',
};

/// Where to get a key, shown in the form. Nobody should have to go hunting.
String keyHelpFor(AiProviderKind kind) => switch (kind) {
  AiProviderKind.gemini => 'Clé gratuite sur aistudio.google.com/apikey',
  AiProviderKind.openAiCompatible =>
    'La clé de votre fournisseur : OpenAI, Groq, OpenRouter, Mistral…',
};

/// What the model is asked to do.
///
/// Editable on purpose — it is the part most worth adjusting once you see how
/// a given model answers on your own files, and no default survives contact
/// with every naming habit.
///
/// Two things it must keep saying, whatever else changes: answer as JSON, and
/// leave a field empty rather than invent. The parser depends on the first, and
/// a confident wrong artist is worse than a blank one, since the user is
/// looking at both fields anyway.
const String defaultAiInstruction = '''
Tu reçois le nom d'un fichier audio. Il vient souvent d'un téléchargement et
porte des mentions parasites : nom de chaîne, « Official Video », « Lyrics »,
résolution, année d'upload.

Déduis l'artiste et le titre réels du morceau.

Règles :
- Retire tout ce qui n'appartient pas au nom de l'œuvre.
- Garde ce qui en fait partie : « (Remix) », « feat. X », « (Live) », « (Acoustic) ».
- L'ordre n'est pas toujours « artiste - titre ». Déduis-le du sens.
- Si le nom ne permet pas de trancher, laisse le champ vide plutôt que d'inventer.

Réponds uniquement par un objet JSON, sans texte autour :
{"artist": "...", "title": "..."}
''';

/// Reads and writes the providers and the instruction.
///
/// Metadata lives in the app's private support directory; API keys live in
/// the platform vault. Serialize the complete operation, including vault
/// updates and rollback, across store instances in this isolate.
class AiSettingsStore {
  static const String _fileName = 'ai_providers.json';
  static final Lock _lock = Lock();

  final AiSecretVault _vault;
  final Directory? supportDir;

  AiSettingsStore({AiSecretVault? vault, this.supportDir})
    : _vault = vault ?? const PlatformAiSecretVault();

  Future<File> _file() async {
    final dir = supportDir ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Map<String, Object?> _nonSecretJson(AiProviderConfig provider) => {
    ...provider.toJson(),
    'apiKey': '',
  };

  Future<AiSettings> load() =>
      _lock.synchronized(() => _load(preferFileSecrets: false));

  /// Compatibility entry point for an already-imported legacy JSON file.
  /// New imports use [importTransaction] so keys never pass through that file.
  Future<AiSettings> loadImported() =>
      _lock.synchronized(() => _load(preferFileSecrets: true));

  Future<AiSettings> _load({required bool preferFileSecrets}) async {
    try {
      final file = await _file();
      if (!await file.exists()) return const AiSettings();

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['providers'] is! List) {
        throw const FormatException('Réglages IA illisibles.');
      }

      final rawProviders = decoded['providers'] as List;
      final ids = <String>{};
      final providers = <AiProviderConfig>[];
      var needsMigration = false;
      for (final entry in rawProviders) {
        final provider = AiProviderConfig.fromJson(entry);
        if (provider == null || !ids.add(provider.id)) {
          throw const FormatException('Fournisseur IA invalide ou dupliqué.');
        }
        final legacyKey = provider.apiKey;
        var key = await _vault.read(provider.id);
        if (legacyKey.isNotEmpty) {
          // Migration is deliberately fail-closed: do not erase the legacy
          // plaintext until the keystore has acknowledged every credential.
          if (preferFileSecrets || key == null || key.isEmpty) {
            await _vault.write(provider.id, legacyKey);
            key = legacyKey;
          }
          needsMigration = true;
        }
        providers.add(provider.copyWith(apiKey: key ?? ''));
      }
      if (needsMigration) {
        await AtomicFile.writeString(
          file,
          jsonEncode({
            ...decoded.map((key, value) => MapEntry('$key', value)),
            'providers': [
              for (final provider in providers) _nonSecretJson(provider),
            ],
          }),
        );
      }
      final instruction = decoded['instruction'];
      return AiSettings(
        providers: providers,
        instruction: instruction is String && instruction.trim().isNotEmpty
            ? instruction
            : defaultAiInstruction,
      );
    } catch (error, stack) {
      // Do not silently replace credential-read failures with an empty store
      // and then overwrite it during an unrelated settings update.
      DebugLog.instance.error(
        'Réglages',
        'Impossible de lire/migrer les modèles IA (clés conservées)',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Keeps vault changes and the importer's file rollback in the same lock.
  /// The callback must restore its files before throwing. Imported API keys
  /// are removed from the JSON before the callback writes anything to disk.
  Future<T> importTransaction<T>(
    Future<T> Function(AiSettingsImport transaction) apply,
  ) => _lock.synchronized(() async {
    final file = await _file();
    final Object? current = await file.exists()
        ? jsonDecode(await file.readAsString())
        : null;
    if (current != null && current is! Map) {
      throw const FormatException('Réglages IA existants illisibles.');
    }
    final transaction = AiSettingsImport._(_vault);
    await transaction._readCurrent(current as Map?);
    try {
      return await apply(transaction);
    } catch (_) {
      await transaction._rollback();
      rethrow;
    }
  });

  Future<void> save(AiSettings settings) =>
      _lock.synchronized(() => _save(settings));

  Future<void> _save(AiSettings settings) async {
    final ids = <String>{};
    for (final provider in settings.providers) {
      if (provider.id.isEmpty || !ids.add(provider.id)) {
        throw const FormatException('Identifiant de fournisseur IA invalide.');
      }
    }
    final file = await _file();
    // Migrate first, and fail before saving if the keystore cannot be read.
    final previous = await _load(preferFileSecrets: false);
    final oldKeys = <String, String?>{
      for (final id in <String>{
        ...previous.providers.map((provider) => provider.id),
        ...settings.providers.map((provider) => provider.id),
      })
        id: await _vault.read(id),
    };
    try {
      for (final provider in settings.providers) {
        if (provider.apiKey.isNotEmpty) {
          await _vault.write(provider.id, provider.apiKey);
        } else {
          await _vault.delete(provider.id);
        }
      }
      await AtomicFile.writeString(
        file,
        jsonEncode({
          'providers': [for (final p in settings.providers) _nonSecretJson(p)],
          'instruction': settings.instruction,
        }),
      );
    } catch (_) {
      // Best-effort rollback of secrets if the metadata commit failed.
      // The original file is left unchanged by AtomicFile on write failure.
      for (final entry in oldKeys.entries) {
        try {
          if (entry.value == null) {
            await _vault.delete(entry.key);
          } else {
            await _vault.write(entry.key, entry.value!);
          }
        } catch (error) {
          DebugLog.instance.error(
            'Réglages',
            'Restauration de clé IA impossible',
            error: error,
          );
        }
      }
      rethrow;
    }
    final remaining = settings.providers.map((p) => p.id).toSet();
    for (final old in previous.providers) {
      if (!remaining.contains(old.id)) {
        try {
          await _vault.delete(old.id);
        } catch (error) {
          DebugLog.instance.warning(
            'Réglages',
            'Nettoyage de clé IA supprimée impossible',
            error: error,
          );
        }
      }
    }
  }
}

/// Vault part of a settings import; created only while the store is locked.
class AiSettingsImport {
  final AiSecretVault _vault;
  final Map<String, String?> _before = {};
  final Set<String> _changed = {};
  Map<String, Object?>? currentJson;

  AiSettingsImport._(this._vault);

  Future<void> _remember(String id) async {
    if (!_before.containsKey(id)) _before[id] = await _vault.read(id);
  }

  Future<void> _readCurrent(Map? raw) async {
    if (raw == null) return;
    final rows = raw['providers'];
    if (rows is! List) {
      throw const FormatException('Réglages IA existants illisibles.');
    }
    final hydrated = <Object?>[];
    for (final row in rows) {
      final provider = AiProviderConfig.fromJson(row);
      if (provider == null || row is! Map) {
        throw const FormatException('Fournisseur IA existant illisible.');
      }
      await _remember(provider.id);
      final stored = _before[provider.id];
      hydrated.add({
        ...row,
        'apiKey': stored == null || stored.isEmpty ? provider.apiKey : stored,
      });
    }
    currentJson = {
      for (final entry in raw.entries) '${entry.key}': entry.value,
      'providers': hydrated,
    };
  }

  /// Stages merged credentials and returns JSON with no provider API keys.
  Future<Map<String, Object?>> prepare(Map imported) async {
    final rows = imported['providers'] as List;
    final providers = <AiProviderConfig>[];
    final ids = <String>{};
    for (final row in rows) {
      final provider = AiProviderConfig.fromJson(row);
      if (provider == null || !ids.add(provider.id)) {
        throw const FormatException('Fournisseur IA invalide ou dupliqué.');
      }
      providers.add(provider);
      await _remember(provider.id);
    }
    // All reads finish before the first write. Track a write before awaiting
    // it: a platform error can arrive after the platform changed the value.
    for (final provider in providers) {
      _changed.add(provider.id);
      if (provider.apiKey.isEmpty) {
        await _vault.delete(provider.id);
      } else {
        await _vault.write(provider.id, provider.apiKey);
      }
    }
    for (final id in _before.keys) {
      if (ids.contains(id)) continue;
      _changed.add(id);
      await _vault.delete(id);
    }
    return {
      for (final entry in imported.entries) '${entry.key}': entry.value,
      'providers': [
        for (final row in rows) {...row as Map, 'apiKey': ''},
      ],
    };
  }

  Future<void> _rollback() async {
    var failed = false;
    for (final id in _changed) {
      try {
        final value = _before[id];
        if (value == null) {
          await _vault.delete(id);
        } else {
          await _vault.write(id, value);
        }
      } catch (_) {
        failed = true;
      }
    }
    if (failed) {
      throw StateError(
        'Import interrompu : certaines clés IA n’ont pas pu être restaurées.',
      );
    }
  }
}

@immutable
class AiSettings {
  final List<AiProviderConfig> providers;
  final String instruction;

  const AiSettings({
    this.providers = const [],
    this.instruction = defaultAiInstruction,
  });

  /// Everything switched on with a key, in the order the user arranged them.
  ///
  /// The order is the fallback order: the first is asked, and the next only if
  /// it fails technically. They are not all asked — this is one small question,
  /// and three models answering it would cost three round trips to disagree.
  List<AiProviderConfig> get usable =>
      providers.where((p) => p.isUsable).toList(growable: false);

  /// The first that will be asked.
  AiProviderConfig? get active => usable.firstOrNull;

  AiSettings copyWith({
    List<AiProviderConfig>? providers,
    String? instruction,
  }) => AiSettings(
    providers: providers ?? this.providers,
    instruction: instruction ?? this.instruction,
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
