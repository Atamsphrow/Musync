// Editing a model must not be able to blank it: `edit` applies the same
// defaults as `add` when a field comes back empty.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';

class _MemoryStore extends AiSettingsStore {
  AiSettings settings;

  _MemoryStore(this.settings);

  @override
  Future<AiSettings> load() async => settings;

  @override
  Future<void> save(AiSettings next) async {
    settings = next;
  }
}

void main() {
  late _MemoryStore store;
  late ProviderContainer container;

  setUp(() {
    store = _MemoryStore(const AiSettings());
    container = ProviderContainer(
      overrides: [aiSettingsStoreProvider.overrideWithValue(store)],
    );
  });

  tearDown(container.dispose);

  Future<String> addGemini() async {
    final notifier = container.read(aiSettingsProvider.notifier);
    await container.read(aiSettingsProvider.future);
    await notifier.add(
      name: 'Gemini',
      kind: AiProviderKind.gemini,
      baseUrl: '',
      model: '',
      apiKey: 'k',
    );
    return store.settings.providers.single.id;
  }

  test('edit with blank fields falls back to the add defaults', () async {
    final id = await addGemini();

    await container
        .read(aiSettingsProvider.notifier)
        .edit(id, name: '', baseUrl: '   ', model: '');

    final edited = store.settings.providers.single;
    expect(edited.name, labelFor(AiProviderKind.gemini));
    expect(edited.baseUrl, defaultBaseUrlFor(AiProviderKind.gemini));
    expect(edited.model, defaultModelFor(AiProviderKind.gemini));
    // The key has no default in `add` either: it is left alone.
    expect(edited.apiKey, 'k');
  });

  test('edit without a field keeps the stored value', () async {
    final id = await addGemini();

    await container.read(aiSettingsProvider.notifier).edit(id);

    final edited = store.settings.providers.single;
    expect(edited.name, 'Gemini');
    expect(edited.baseUrl, defaultBaseUrlFor(AiProviderKind.gemini));
    expect(edited.model, defaultModelFor(AiProviderKind.gemini));
  });

  test('edit with a new kind follows the new kind for its defaults', () async {
    final id = await addGemini();

    await container
        .read(aiSettingsProvider.notifier)
        .edit(
          id,
          kind: AiProviderKind.openAiCompatible,
          name: '',
          baseUrl: '',
          model: '',
        );

    final edited = store.settings.providers.single;
    expect(edited.kind, AiProviderKind.openAiCompatible);
    expect(edited.name, labelFor(AiProviderKind.openAiCompatible));
    expect(edited.baseUrl, defaultBaseUrlFor(AiProviderKind.openAiCompatible));
    expect(edited.model, defaultModelFor(AiProviderKind.openAiCompatible));
  });
}
