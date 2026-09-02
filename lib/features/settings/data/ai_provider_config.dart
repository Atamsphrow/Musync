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
import 'package:musync/core/services/debug_log.dart';
import 'package:path_provider/path_provider.dart';

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

  /// The secret. Kept in the app's private storage and never logged — see
  /// [redactedKey], which is the only form anything else is allowed to show.
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
/// A file in the app's private storage, like the lyrics sources. It holds an
/// API key, so it must never be somewhere another app can read: this is
/// `getApplicationSupportDirectory`, which on Android is inside the app's own
/// sandbox.
class AiSettingsStore {
  static const String _fileName = 'ai_providers.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<AiSettings> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const AiSettings();

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const AiSettings();

      final instruction = decoded['instruction'];
      return AiSettings(
        providers: [
          for (final entry in (decoded['providers'] as List? ?? const []))
            ?AiProviderConfig.fromJson(entry),
        ],
        instruction: instruction is String && instruction.trim().isNotEmpty
            ? instruction
            : defaultAiInstruction,
      );
    } catch (error, stack) {
      // Unreadable settings must not stop the app; the button simply falls back
      // to the heuristic.
      //
      // But from the user's side this is indistinguishable from their keys
      // having been forgotten, and they would go and type them in again. No key
      // material in the message — the file holds secrets, so nothing about its
      // contents is quoted, only that it could not be read.
      DebugLog.instance.error(
        'Réglages',
        'Fichier des modèles IA illisible : aucun modèle ne sera utilisé, et '
            'les clés enregistrées semblent absentes',
        error: error,
        stackTrace: stack,
      );
      return const AiSettings();
    }
  }

  Future<void> save(AiSettings settings) async {
    await AtomicFile.writeString(
      await _file(),
      jsonEncode({
        'providers': [for (final p in settings.providers) p.toJson()],
        'instruction': settings.instruction,
      }),
    );
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
