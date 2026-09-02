/// Settings › IA: the models, their keys, and what they are told to do.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';

class AiTab extends ConsumerWidget {
  const AiTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(aiSettingsProvider);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (settings) => ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Sur l\'écran de recherche, « Deviner depuis le nom du '
                'fichier » lit d\'abord le nom lui-même, sans réseau. Un modèle '
                'configuré ici prend le relais sur les noms qu\'il n\'arrive '
                'pas à trancher — un titre placé avant l\'artiste, par exemple.'
                '\n\nSeul le nom du fichier est envoyé. Jamais l\'audio, jamais '
                'les paroles.',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),

            const _InstructionCard(),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                'Modèles',
                style: textTheme.titleSmall?.copyWith(color: scheme.primary),
              ),
            ),

            if (settings.providers.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  'Aucun modèle. Sans modèle, le bouton se contente de '
                  'l\'analyse du nom de fichier, qui suffit dans la plupart '
                  'des cas.',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),

            for (final provider in settings.providers)
              _ProviderTile(provider: provider, key: ValueKey(provider.id)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter un modèle'),
      ),
    );
  }
}

/// The instruction, editable and foldable.
///
/// Folded by default: it is long, and most people will never touch it. It is
/// also the first thing worth adjusting when a model answers badly, so it lives
/// here rather than being buried in the code.
class _InstructionCard extends ConsumerStatefulWidget {
  const _InstructionCard();

  @override
  ConsumerState<_InstructionCard> createState() => _InstructionCardState();
}

class _InstructionCardState extends ConsumerState<_InstructionCard> {
  TextEditingController? _controller;
  bool _open = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(aiSettingsProvider).valueOrNull;
    if (settings == null) return const SizedBox.shrink();

    // Created on first open, from the stored value. Not rebuilt afterwards, so
    // typing is never interrupted by the save that typing itself triggers.
    _controller ??= TextEditingController(text: settings.instruction);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.assignment_outlined),
            title: const Text('Instruction donnée au modèle'),
            subtitle: Text(
              _open
                  ? 'Enregistrée en quittant le champ'
                  : 'Ce qu\'on lui demande de faire, et comment répondre',
            ),
            trailing: Icon(_open ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _open = !_open),
          ),
          if (_open) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Focus(
                // Saved on focus loss rather than on each keystroke: this is a
                // paragraph, not a switch, and writing the file twenty times a
                // second while someone types would be absurd.
                onFocusChange: (hasFocus) {
                  if (hasFocus) return;
                  ref
                      .read(aiSettingsProvider.notifier)
                      .setInstruction(_controller!.text);
                },
                child: TextField(
                  controller: _controller,
                  maxLines: null,
                  minLines: 6,
                  style: Theme.of(context).textTheme.bodySmall,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    helperText:
                        'Doit demander une réponse en JSON '
                        '{"artist": "...", "title": "..."}',
                    helperMaxLines: 2,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 4),
                child: TextButton.icon(
                  onPressed: () {
                    _controller!.text = defaultAiInstruction;
                    ref
                        .read(aiSettingsProvider.notifier)
                        .setInstruction(defaultAiInstruction);
                  },
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('Rétablir le texte par défaut'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProviderTile extends ConsumerWidget {
  final AiProviderConfig provider;

  const _ProviderTile({super.key, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(aiSettingsProvider.notifier);
    final status = ref.watch(aiProviderStatusProvider)[provider.id];

    return Column(
      children: [
        SwitchListTile(
          value: provider.enabled,
          onChanged: (value) => notifier.setEnabled(provider.id, value),
          title: Text(provider.name),
          // The key is shown redacted and never in full: this screen gets
          // pointed at, screenshotted and shared.
          subtitle: Text(
            '${provider.model} · ${provider.redactedKey}',
            maxLines: 1,
            overflow: TextOverflow.fade,
          ),
          secondary: PopupMenuButton<_Action>(
            onSelected: (action) => switch (action) {
              _Action.check =>
                ref.read(aiProviderStatusProvider.notifier).check(provider),
              _Action.edit => _openEditor(context, ref, existing: provider),
              _Action.delete => _confirmDelete(context, ref, provider),
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _Action.check,
                child: ListTile(
                  leading: Icon(Icons.published_with_changes),
                  title: Text('Vérifier'),
                  subtitle: Text('Le modèle existe-t-il encore ?'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _Action.edit,
                child: ListTile(
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Modifier'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _Action.delete,
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Supprimer'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
        if (status != null) _StatusLine(status: status),
      ],
    );
  }
}

/// The last thing this provider did, next to the setting that caused it.
///
/// The point of showing it here: with three providers configured, "the AI does
/// not work" was one line in the Journal tab that had to be found and read. Now
/// each entry says for itself whether it answered, and why not.
class _StatusLine extends StatelessWidget {
  final AiProviderStatus status;

  const _StatusLine({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // Three states, not two: `ok == null` is "we could not tell", which must
    // not be shown as a failure.
    final (icon, colour) = switch (status.ok) {
      true => (Icons.check_circle_outline, scheme.primary),
      false => (Icons.error_outline, scheme.error),
      null => (Icons.help_outline, scheme.onSurfaceVariant),
    };

    return Padding(
      padding: const EdgeInsets.only(left: 72, right: 16, bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status.checking)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, size: 16, color: colour),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status.checking
                  ? 'Vérification…'
                  : (status.detail ?? 'État inconnu.'),
              style: textTheme.bodySmall?.copyWith(color: colour),
            ),
          ),
        ],
      ),
    );
  }
}

enum _Action { check, edit, delete }

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  AiProviderConfig provider,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Supprimer « ${provider.name} » ?'),
      content: const Text('La clé enregistrée sera effacée.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    // The status is keyed by id, and ids come from a timestamp — so a stale
    // entry would not be reused by a new provider, but it would sit in the map
    // forever. Dropped with the thing it describes.
    ref.read(aiProviderStatusProvider.notifier).forget(provider.id);
    await ref.read(aiSettingsProvider.notifier).remove(provider.id);
  }
}

typedef _FormResult = ({
  String name,
  AiProviderKind kind,
  String baseUrl,
  String model,
  String apiKey,
});

Future<void> _openEditor(
  BuildContext context,
  WidgetRef ref, {
  AiProviderConfig? existing,
}) async {
  final result = await showDialog<_FormResult>(
    context: context,
    builder: (context) => _ProviderDialog(existing: existing),
  );
  if (result == null) return;

  final notifier = ref.read(aiSettingsProvider.notifier);
  if (existing == null) {
    await notifier.add(
      name: result.name,
      kind: result.kind,
      baseUrl: result.baseUrl,
      model: result.model,
      apiKey: result.apiKey,
    );
  } else {
    await notifier.edit(
      existing.id,
      name: result.name,
      kind: result.kind,
      baseUrl: result.baseUrl,
      model: result.model,
      apiKey: result.apiKey,
    );
  }
}

/// Add/edit form. Owns its controllers — see `_LineTextDialog` for why that is
/// not optional.
class _ProviderDialog extends ConsumerStatefulWidget {
  final AiProviderConfig? existing;

  const _ProviderDialog({this.existing});

  @override
  ConsumerState<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends ConsumerState<_ProviderDialog> {
  late AiProviderKind _kind = widget.existing?.kind ?? AiProviderKind.gemini;

  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _baseUrl = TextEditingController(
    text: widget.existing?.baseUrl ?? defaultBaseUrlFor(_kind),
  );
  late final TextEditingController _model = TextEditingController(
    text: widget.existing?.model ?? defaultModelFor(_kind),
  );
  late final TextEditingController _apiKey = TextEditingController(
    text: widget.existing?.apiKey ?? '',
  );

  bool _showKey = false;
  String? _keyError;

  /// What the provider says it serves, once asked.
  ///
  /// Null until a scan has been run — which is not the same as an empty list,
  /// and the difference is what the UI below shows.
  List<String>? _models;
  bool _scanning = false;
  String? _scanError;

  /// Asks the provider for its catalogue, using the values in the form.
  ///
  /// The form's values and not the saved ones: the whole point is to scan
  /// *before* committing a model name, and on a provider that may not be saved
  /// yet at all. A model identifier is the provider's to change and they do —
  /// `gemini-2.0-flash` was retired under this app's feet — so typing one from
  /// memory is a setting that expires. This makes the list the source.
  Future<void> _scanModels() async {
    if (_apiKey.text.trim().isEmpty) {
      setState(() => _scanError = 'Il faut une clé pour interroger la liste.');
      return;
    }

    setState(() {
      _scanning = true;
      _scanError = null;
    });

    final draft = AiProviderConfig(
      id: widget.existing?.id ?? 'scan',
      name: _name.text.trim().isEmpty ? labelFor(_kind) : _name.text.trim(),
      kind: _kind,
      baseUrl: _baseUrl.text.trim().isEmpty
          ? defaultBaseUrlFor(_kind)
          : _baseUrl.text.trim(),
      model: _model.text.trim(),
      apiKey: _apiKey.text.trim(),
    );

    try {
      final models = await ref.read(aiFilenameReaderProvider).listModels(draft);
      if (!mounted) return;
      setState(() {
        _models = models;
        _scanError = models.isEmpty
            ? 'Ce fournisseur ne publie pas la liste de ses modèles.'
            : null;
      });
    } on AiReaderException catch (e) {
      if (!mounted) return;
      // The reason matters: a refused key and a provider with no listing
      // endpoint are two different things to do about it.
      setState(() {
        _models = null;
        _scanError = e.message;
      });
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  /// Follows the kind, unless the user has typed something of their own.
  void _onKindChanged(AiProviderKind kind) {
    setState(() {
      final wasDefaultUrl =
          _baseUrl.text.trim() == defaultBaseUrlFor(_kind) ||
          _baseUrl.text.trim().isEmpty;
      final wasDefaultModel =
          _model.text.trim() == defaultModelFor(_kind) ||
          _model.text.trim().isEmpty;

      _kind = kind;
      if (wasDefaultUrl) _baseUrl.text = defaultBaseUrlFor(kind);
      if (wasDefaultModel) _model.text = defaultModelFor(kind);
    });
  }

  void _submit() {
    if (_apiKey.text.trim().isEmpty) {
      setState(() => _keyError = 'Sans clé, le modèle ne sera pas interrogé.');
      return;
    }
    Navigator.pop(context, (
      name: _name.text,
      kind: _kind,
      baseUrl: _baseUrl.text,
      model: _model.text,
      apiKey: _apiKey.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Nouveau modèle' : 'Modifier le modèle',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<AiProviderKind>(
              segments: [
                for (final kind in AiProviderKind.values)
                  ButtonSegment(value: kind, label: Text(labelFor(kind))),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => _onKindChanged(s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: 'Nom',
                hintText: labelFor(_kind),
                helperText: 'Pour vous y retrouver dans la liste',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKey,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Clé API',
                errorText: _keyError,
                helperText: keyHelpFor(_kind),
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  icon: Icon(
                    _showKey ? Icons.visibility_off : Icons.visibility,
                  ),
                  tooltip: _showKey ? 'Masquer' : 'Afficher',
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _model,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Modèle',
                hintText: defaultModelFor(_kind),
                // Kept typable. A model served locally is often absent from any
                // listing, and a picker that refuses what the provider does not
                // advertise would lock that case out.
                suffixIcon: IconButton(
                  onPressed: _scanning ? null : _scanModels,
                  tooltip: 'Scanner les modèles disponibles',
                  icon: _scanning
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.travel_explore),
                ),
              ),
            ),
            if (_scanError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _scanError!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            if (_models != null && _models!.isNotEmpty) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _models!.contains(_model.text.trim())
                    ? _model.text.trim()
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: '${_models!.length} modèle(s) disponible(s)',
                  helperText: 'Choisir remplit le champ ci-dessus',
                ),
                items: [
                  for (final model in _models!)
                    DropdownMenuItem(
                      value: model,
                      child: Text(model, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (model) {
                  if (model != null) setState(() => _model.text = model);
                },
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrl,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'Adresse de l\'API',
                hintText: defaultBaseUrlFor(_kind),
                helperText:
                    'À changer pour Groq, OpenRouter, un serveur local…',
                helperMaxLines: 2,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Enregistrer')),
      ],
    );
  }
}
