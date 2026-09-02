/// The configured language models, and the instruction they are given.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/lyrics/data/ai_filename_resolver.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';

final aiSettingsStoreProvider = Provider<AiSettingsStore>(
  (ref) => AiSettingsStore(),
);

final aiFilenameReaderProvider = Provider<AiFilenameReader>(
  (ref) => AiFilenameReader(),
);

final aiFilenameResolverProvider = Provider<AiFilenameResolver>(
  (ref) => AiFilenameResolver(ref.read(aiFilenameReaderProvider)),
);

/// What each provider did last time it was asked, keyed by provider id.
///
/// Exists so the answer is in the tab where the setting lives. It used to be
/// findable only by opening the Journal tab and reading through it, which is a
/// lot to ask of someone who just wants to know which of their three keys works.
final aiProviderStatusProvider =
    NotifierProvider<AiProviderStatusNotifier, Map<String, AiProviderStatus>>(
      AiProviderStatusNotifier.new,
    );

/// The last known state of one provider.
@immutable
class AiProviderStatus {
  /// Null while nothing has been tried.
  final bool? ok;

  /// Why it failed, or what the model check found. Shown as-is.
  final String? detail;

  /// True while a check is in flight, so the tile can show a spinner.
  final bool checking;

  const AiProviderStatus({this.ok, this.detail, this.checking = false});
}

class AiProviderStatusNotifier extends Notifier<Map<String, AiProviderStatus>> {
  @override
  Map<String, AiProviderStatus> build() => const {};

  void _set(String id, AiProviderStatus status) {
    state = {...state, id: status};
  }

  /// Records the outcome of a real use, so the tab reflects what actually
  /// happened rather than only what a manual check said.
  void recordAttempts(List<AiAttempt> attempts) {
    if (attempts.isEmpty) return;
    state = {
      ...state,
      for (final a in attempts)
        a.providerId: a.ok
            ? const AiProviderStatus(ok: true, detail: 'A répondu.')
            : AiProviderStatus(ok: false, detail: a.failure!.detail),
    };
  }

  void forget(String id) {
    final next = {...state}..remove(id);
    state = next;
  }

  /// Asks the provider whether its model still exists (T27).
  Future<void> check(AiProviderConfig provider) async {
    if (!provider.isUsable) {
      _set(
        provider.id,
        const AiProviderStatus(ok: false, detail: 'Désactivé, ou sans clé.'),
      );
      return;
    }

    _set(provider.id, const AiProviderStatus(checking: true));
    final result = await ref
        .read(aiFilenameReaderProvider)
        .checkModel(provider);

    _set(provider.id, switch (result) {
      AiModelCheck.present => AiProviderStatus(
        ok: true,
        detail: 'Modèle ${provider.model} disponible.',
      ),
      AiModelCheck.missing => AiProviderStatus(
        ok: false,
        detail:
            'Le modèle ${provider.model} n\'existe plus chez ce '
            'fournisseur. Choisissez-en un autre.',
      ),
      AiModelCheck.keyRejected => const AiProviderStatus(
        ok: false,
        detail: 'Clé refusée.',
      ),
      // Not a failure: it is the check that could not be made, not the
      // provider that is broken. Saying otherwise would send the user
      // editing a setting that is probably correct.
      AiModelCheck.unknown => const AiProviderStatus(
        detail:
            'Vérification impossible — pas de réseau, ou ce fournisseur '
            'ne publie pas la liste de ses modèles.',
      ),
    });
  }
}

final aiSettingsProvider =
    AsyncNotifierProvider<AiSettingsNotifier, AiSettings>(
      AiSettingsNotifier.new,
    );

class AiSettingsNotifier extends AsyncNotifier<AiSettings> {
  @override
  Future<AiSettings> build() => ref.read(aiSettingsStoreProvider).load();

  Future<void> _commit(AiSettings next) async {
    state = AsyncValue.data(next);
    try {
      await ref.read(aiSettingsStoreProvider).save(next);
    } catch (error, stack) {
      // No provider details in the message: `AiProviderConfig.toString` redacts
      // the key, but the safest habit is not to name one at all here.
      DebugLog.instance.error(
        'Réglages',
        'Enregistrement des modèles impossible',
        error: error,
        stackTrace: stack,
      );
    }
  }

  AiSettings get _current => state.valueOrNull ?? const AiSettings();

  Future<void> add({
    required String name,
    required AiProviderKind kind,
    required String baseUrl,
    required String model,
    required String apiKey,
  }) async {
    await _commit(
      _current.copyWith(
        providers: [
          ..._current.providers,
          AiProviderConfig(
            id: 'ai-${DateTime.now().microsecondsSinceEpoch}',
            name: name.trim().isEmpty ? labelFor(kind) : name.trim(),
            kind: kind,
            baseUrl: baseUrl.trim().isEmpty
                ? defaultBaseUrlFor(kind)
                : baseUrl.trim(),
            model: model.trim().isEmpty ? defaultModelFor(kind) : model.trim(),
            apiKey: apiKey.trim(),
          ),
        ],
      ),
    );
  }

  Future<void> edit(
    String id, {
    String? name,
    AiProviderKind? kind,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) async {
    await _commit(
      _current.copyWith(
        providers: [
          for (final p in _current.providers)
            if (p.id == id)
              p.copyWith(
                name: name?.trim(),
                kind: kind,
                baseUrl: baseUrl?.trim(),
                model: model?.trim(),
                apiKey: apiKey?.trim(),
              )
            else
              p,
        ],
      ),
    );
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await _commit(
      _current.copyWith(
        providers: [
          for (final p in _current.providers)
            if (p.id == id) p.copyWith(enabled: enabled) else p,
        ],
      ),
    );
  }

  Future<void> remove(String id) async {
    await _commit(
      _current.copyWith(
        providers: [
          for (final p in _current.providers)
            if (p.id != id) p,
        ],
      ),
    );
  }

  /// Replaces the instruction. Blank restores the default rather than leaving
  /// the model with nothing to go on.
  Future<void> setInstruction(String instruction) async {
    await _commit(
      _current.copyWith(
        instruction: instruction.trim().isEmpty
            ? defaultAiInstruction
            : instruction,
      ),
    );
  }
}
