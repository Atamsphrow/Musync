/// Settings › IA: the models, their keys, and what they are told to do.
library;
import 'dart:async' show scheduleMicrotask, unawaited;
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/ai_assistant/data/automation.dart';
import 'package:musync/features/ai_assistant/data/scheduler_bridge.dart';
import 'package:musync/features/ai_assistant/providers/automation_provider.dart';
import 'package:musync/features/settings/data/ai_model_probe.dart';
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
            // iOS : pas d'alarmes exactes ni de déclencheur écouteurs.
            if (!Platform.isIOS) const _AutomationsSection(),
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
                  'Aucun modèle.',
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
      // Disabled until the stored settings have loaded: `add` starts from
      // the current state, and an empty one would overwrite the providers
      // already on disk with just the new model.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: settingsAsync.hasValue
            ? () => _openEditor(context, ref)
            : null,
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
  // The notifier, captured while the widget is alive: `ref` must not be
  // used in dispose, and the Focus listener is gone by then (see below).
  AiSettingsNotifier? _notifier;
  // What the field held the last time it was saved, so dispose only
  // writes when something actually changed.
  String? _savedInstruction;
  bool _open = false;
  @override
  void dispose() {
    // The Focus widget removes its listener before the detach unfocuses
    // the field (SDK _FocusState.dispose), so onFocusChange(false) never
    // fires here: without this save, closing the screen with the field
    // focused would drop the edit.
    final controller = _controller;
    final notifier = _notifier;
    if (controller != null &&
        notifier != null &&
        controller.text != _savedInstruction) {
      // Deferred past this frame: dispose runs while the tree is being
      // rebuilt (the screen is closing), and Riverpod forbids modifying a
      // provider mid-build — the direct call throws in debug and the edit
      // would be lost. A microtask runs right after the build.
      final text = controller.text;
      scheduleMicrotask(() => unawaited(notifier.setInstruction(text)));
    }
    _controller?.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(aiSettingsProvider).valueOrNull;
    if (settings == null) return const SizedBox.shrink();
    _notifier ??= ref.read(aiSettingsProvider.notifier);
    // Created on first open, from the stored value. Not rebuilt afterwards, so
    // typing is never interrupted by the save that typing itself triggers.
    _controller ??= TextEditingController(text: settings.instruction);
    _savedInstruction ??= settings.instruction;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.assignment_outlined),
            title: const Text('Instruction donnée au modèle'),
            subtitle: _open
                ? const Text('Enregistrée en quittant le champ ou l\u2019écran')
                : null,
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
                  _savedInstruction = _controller!.text;
                  ref
                      .read(aiSettingsProvider.notifier)
                      .setInstruction(_controller!.text);
                },
                child: TextField(
                  controller: _controller,
                  // Le curseur ne reste pas affiché une fois le clavier fermé.
                  onTapOutside: (_) =>
                      FocusManager.instance.primaryFocus?.unfocus(),
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
                    _savedInstruction = defaultAiInstruction;
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
              _Action.ping =>
                ref.read(aiProviderStatusProvider.notifier).ping(provider),
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
                value: _Action.ping,
                child: ListTile(
                  leading: Icon(Icons.mark_chat_read_outlined),
                  title: Text('Tester la réponse'),
                  subtitle: Text('Le modèle répond-il vraiment ?'),
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
enum _Action { check, ping, edit, delete }
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
    if (!context.mounted) return;
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
  if (!context.mounted) return;
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
  /// What the probe found per model, as results arrive.
  ///
  /// A model is absent until its probe answers: the mark is live, not a
  /// batch applied at the end. Cleared on every re-scan.
  final Map<String, AiModelPing> _probeResults = {};
  /// True while a probe batch is running.
  bool _probing = false;
  /// Why a batch stopped early, if it did (refused key, rate limit).
  String? _probeStop;
  /// The batch in flight, if any. Bumped on every scan and on dispose, so
  /// a superseded batch can neither write into the new results nor call
  /// setState on a disposed widget.
  int _probeRun = 0;
  /// The provider config the form describes right now: the scan and
  /// the probe both run on the draft, never on the saved provider.
  AiProviderConfig _draft() => AiProviderConfig(
    id: widget.existing?.id ?? 'scan',
    name: _name.text.trim().isEmpty ? labelFor(_kind) : _name.text.trim(),
    kind: _kind,
    baseUrl: _baseUrl.text.trim().isEmpty
        ? defaultBaseUrlFor(_kind)
        : _baseUrl.text.trim(),
    model: _model.text.trim(),
    apiKey: _apiKey.text.trim(),
  );
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
    // A new scan supersedes any probe batch still running.
    final runId = ++_probeRun;
    setState(() {
      _scanning = true;
      _scanError = null;
      _probeResults.clear();
      _probeStop = null;
      _probing = false;
    });
    final draft = _draft();
    try {
      final models = await ref.read(aiFilenameReaderProvider).listModels(draft);
      if (!mounted || runId != _probeRun) return;
      setState(() {
        _models = models;
        _scanError = models.isEmpty
            ? 'Ce fournisseur ne publie pas la liste de ses modèles.'
            : null;
      });
      if (models.isNotEmpty) {
        unawaited(_probeModels(draft, models, runId));
      }
    } on AiReaderException catch (e) {
      if (!mounted || runId != _probeRun) return;
      // The reason matters: a refused key and a provider with no listing
      // endpoint are two different things to do about it.
      setState(() {
        _models = null;
        _scanError = e.message;
      });
    } finally {
      if (mounted && runId == _probeRun) {
        setState(() => _scanning = false);
      }
    }
  }
  /// Probes every scanned model, one at a time, marking each answer live.
  ///
  /// The draft's model is swapped per candidate: the probe asks the
  /// provider about *that* model, not the one typed in the form. A refused
  /// key or a rate limit stops the batch — both poison every remaining
  /// probe. Closing the dialog (or re-scanning) cancels it via [_probeRun].
  /// A stopped batch can be resumed with [_resumeProbe], which re-probes
  /// only the models never judged (plus the interrupted one).
  Future<void> _probeModels(
    AiProviderConfig draft,
    List<String> models,
    int runId,
  ) async {
    if (!mounted || runId != _probeRun) return;
    setState(() => _probing = true);
    final reader = ref.read(aiFilenameReaderProvider);
    final outcome = await AiModelProbe.run(
      models: models,
      ping: (model) => reader.pingModel(draft.copyWith(model: model)),
      onResult: (model, result) {
        if (!mounted || runId != _probeRun) return;
        setState(() => _probeResults[model] = result);
      },
      isCancelled: () => !mounted || runId != _probeRun,
    );
    if (!mounted || runId != _probeRun) return;
    setState(() {
      _probing = false;
      _probeStop = switch (outcome) {
        AiModelProbeOutcome.stoppedKeyRejected =>
          'Clé refusée, tests arrêtés.',
        AiModelProbeOutcome.stoppedRateLimited =>
          'Limite atteinte (HTTP 429), tests arrêtés.',
        _ => null,
      };
    });
  }
  /// Resumes a batch stopped early (refused key, rate limit) from the
  /// first model never judged.
  ///
  /// The interrupted model's stop result is not a verdict on it — the
  /// provider refused the call itself — so it is dropped and retested,
  /// and every other mark is kept. A new 429 / refused key stops the
  /// resumed batch the same way, with a fresh message.
  Future<void> _resumeProbe() async {
    final models = _models;
    if (models == null || _probing || _probeStop == null) return;
    final remaining = AiModelProbe.remaining(
      models: models,
      results: _probeResults,
    );
    if (remaining.isEmpty) return;
    setState(() {
      for (final model in remaining) {
        _probeResults.remove(model);
      }
      _probeStop = null;
    });
    unawaited(_probeModels(_draft(), remaining, _probeRun));
  }
  /// True when [model] is the one being probed right now: probes run in
  /// order, so it is the first model of the list with no result yet.
  bool _isNextToProbe(String model) {
    if (!_probing) return false;
    for (final candidate in _models ?? const <String>[]) {
      if (!_probeResults.containsKey(candidate)) return candidate == model;
    }
    return false;
  }
  /// « X répondent, Y ne répondent pas » — live, from the results so far.
  /// Unknowns (test impossible) are counted apart: silence from the
  /// network is not a model refusing to answer.
  String _probeSummary() {
    var answered = 0;
    var failed = 0;
    var unknown = 0;
    for (final result in _probeResults.values) {
      switch (result) {
        case AiModelPing.answered:
          answered++;
        case AiModelPing.noAnswer:
        case AiModelPing.keyRejected:
        case AiModelPing.rateLimited:
          failed++;
        case AiModelPing.unknown:
          unknown++;
      }
    }
    final done = _probeResults.length;
    final total = _models?.length ?? done;
    final head = _probing ? 'Test des réponses… $done/$total — ' : '';
    final counts =
        '$answered ${answered == 1 ? 'répond' : 'répondent'}, '
        '$failed ${failed == 1 ? 'ne répond pas' : 'ne répondent pas'}';
    final tail = unknown > 0
        ? ', $unknown indéterminé${unknown == 1 ? '' : 's'}'
        : '';
    return '$head$counts$tail.';
  }
  @override
  void dispose() {
    // A probe batch still running must not write into a disposed dialog.
    ++_probeRun;
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
  /// Whether [url] matches one of the known OpenAI-compatible presets.
  ///
  /// Returns the URL itself when it does — that's what the dropdown binds to.
  /// Returning null leaves the dropdown empty, which is the right answer for
  /// a self-hosted endpoint or anything not in the list.
  String? _matchesPreset(String url) {
    for (final preset in openAiCompatiblePresets) {
      if (preset.baseUrl == url) return url;
    }
    return null;
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
                      child: Row(
                        children: [
                          _ProbeMark(
                            result: _probeResults[model],
                            probing: _isNextToProbe(model),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              model,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: (model) {
                  if (model != null) setState(() => _model.text = model);
                },
              ),
              if (_probing || _probeResults.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _probeSummary(),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (_probeStop != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _probeStop!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_probeStop != null && !_probing)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _resumeProbe,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Reprendre'),
                    ),
                  ),
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
                helperText: switch (_kind) {
                  AiProviderKind.gemini => null,
                  AiProviderKind.openAiCompatible =>
                    'Choisir un fournisseur ci-dessous remplit l\'adresse',
                },
                helperMaxLines: 2,
              ),
            ),
            if (_kind == AiProviderKind.openAiCompatible) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _baseUrl.text.trim().isEmpty
                    ? null
                    : _matchesPreset(_baseUrl.text.trim()),
                decoration: const InputDecoration(
                  labelText: 'Fournisseur prédéfini',
                  helperText:
                      'Pour Groq, OpenRouter, Ollama, etc. Pas pour une URL personnalisée',
                ),
                items: [
                  for (final preset in openAiCompatiblePresets)
                    DropdownMenuItem(
                      value: preset.baseUrl,
                      child: Text(preset.name),
                    ),
                ],
                onChanged: (url) {
                  if (url != null) setState(() => _baseUrl.text = url);
                },
              ),
            ],
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
/// Automatisations de l'assistant : actions planifiées et déclencheur
/// écouteurs. Sobre : la liste, chacune supprimable, rien d'autre.
///
/// La création se fait en langage naturel depuis la recherche (« !tous les
/// jours à 22h, minuteur 30 min ») — pas de formulaire ici, l'utilisateur
/// déteste le fouillis.
/// Automatisations planifiées + déclencheur écouteurs.
///
/// Affiche un bandeau quand les alarmes exactes sont refusées (Android 12+) :
/// sans « Alarmes et rappels », les automatisations sont enregistrées mais ne
/// se déclencheront jamais — c'est exactement ce qui est arrivé le 2026-10-14.
/// Le bandeau se rafraîchit au retour des réglages système.
/// The live probe mark in front of a scanned model name: spinner while
/// the model is being tested, ✓ when it answers, ✗ when it does not, ?
/// when the test could not be made. Nothing for a model not yet reached.
class _ProbeMark extends StatelessWidget {
  final AiModelPing? result;
  final bool probing;
  const _ProbeMark({required this.result, required this.probing});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Local, so the null check below promotes the switch: a field is
    // never promoted, and the switch would demand a `null` case.
    final ping = result;
    if (ping == null) {
      if (!probing) return const SizedBox(width: 20);
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final (icon, colour) = switch (ping) {
      AiModelPing.answered => (Icons.check_circle_outline, scheme.primary),
      AiModelPing.noAnswer ||
      AiModelPing.keyRejected ||
      AiModelPing.rateLimited => (Icons.error_outline, scheme.error),
      AiModelPing.unknown =>
        (Icons.help_outline, scheme.onSurfaceVariant),
    };
    return Icon(icon, size: 20, color: colour);
  }
}
class _AutomationsSection extends ConsumerStatefulWidget {
  const _AutomationsSection();
  @override
  ConsumerState<_AutomationsSection> createState() =>
      _AutomationsSectionState();
}
class _AutomationsSectionState extends ConsumerState<_AutomationsSection>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Retour de l'écran système « Alarmes et rappels » : revérifier, et si
    // la permission vient d'être accordée, réarmer les automatisations
    // existantes — sinon elles ne se déclencheraient jamais (avant, seul le
    // démarrage ou un _commit réarmait le natif).
    if (state == AppLifecycleState.resumed) {
      _recheckExactAlarm();
    }
  }
  Future<void> _recheckExactAlarm() async {
    try {
      final ok = await SchedulerBridge.canScheduleExactAlarms();
      if (!mounted) return;
      final wasGranted = ref.read(exactAlarmGrantedProvider);
      ref.read(exactAlarmGrantedProvider.notifier).state = ok;
      // false → true : accordée hors de l'app, rien n'a jamais été armé.
      // (null → true est couvert par le réarmement au démarrage.)
      if (ok && wasGranted == false) {
        final notifier = ref.read(automationsProvider.notifier);
        await notifier.resync();
        DebugLog.instance.info(
          'Automatisations',
          'Alarmes réarmées après autorisation « Alarmes et rappels »',
        );
      }
    } catch (e) {
      DebugLog.instance.info(
        'Automatisations',
        'Échec du réarmement après autorisation : $e',
      );
    }
  }
  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final automationsAsync = ref.watch(automationsProvider);
    final exactAlarm = ref.watch(exactAlarmGrantedProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            'Automatisations',
            style: textTheme.titleSmall?.copyWith(color: scheme.primary),
          ),
        ),
        if (exactAlarm == false)
          _ExactAlarmBanner(
            key: const ValueKey('exact-alarm-banner'),
            hasAutomations: automationsAsync.valueOrNull?.hasAny ?? false,
          ),
        automationsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('$error', style: textTheme.bodySmall),
          ),
          data: (doc) {
            final actions = doc.actions;
            final trigger = doc.headphoneTrigger;
            if (actions.isEmpty && trigger == null) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  'Aucune. Exemples : « !tous les jours à 22h, minuteur '
                  '30 min », « !demain à 7h, joue ma file Nuit », « !quand '
                  'je branche mes écouteurs, lance ma file Nuit ».',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              );
            }
            return Column(
              children: [
                if (trigger != null)
                  _TriggerTile(
                      trigger: trigger, key: const ValueKey('trigger')),
                for (final action in actions)
                  _ScheduledActionTile(
                    action: action,
                    key: ValueKey(action.id),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
/// Bandeau « Alarmes et rappels » refusées : sans elle, les alarmes exactes
/// ne s'arment pas et les automatisations ne se déclenchent jamais.
class _ExactAlarmBanner extends StatelessWidget {
  final bool hasAutomations;
  const _ExactAlarmBanner({super.key, required this.hasAutomations});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(Icons.alarm_off_outlined, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  hasAutomations
                      ? '« Alarmes et rappels » est désactivé : tes '
                        'automatisations sont enregistrées mais ne se '
                        'déclencheront pas.'
                      : '« Alarmes et rappels » est désactivé : les '
                        'automatisations planifiées ne se déclencheront pas.',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: SchedulerBridge.openExactAlarmSettings,
                child: const Text('Autoriser'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
class _ScheduledActionTile extends ConsumerWidget {
  final ScheduledAction action;
  const _ScheduledActionTile({super.key, required this.action});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(
        action.daily ? Icons.repeat_outlined : Icons.alarm_outlined,
      ),
      title: Text(action.label),
      subtitle: Text(action.describeSchedule()),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Supprimer',
        onPressed: () => _confirmAutomationDelete(
          context,
          'Supprimer « ${action.label} » ?',
          () => ref.read(automationsProvider.notifier).cancel(action.id),
        ),
      ),
    );
  }
}
class _TriggerTile extends ConsumerWidget {
  final HeadphoneTrigger trigger;
  const _TriggerTile({super.key, required this.trigger});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.headphones_outlined),
      title: const Text('Écouteurs branchés'),
      subtitle: Text(trigger.label),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Supprimer',
        onPressed: () => _confirmAutomationDelete(
          context,
          'Supprimer le déclencheur « ${trigger.label} » ?',
          () =>
              ref.read(automationsProvider.notifier).clearHeadphoneTrigger(),
        ),
      ),
    );
  }
}
/// Les suppressions d'automatisations demandent confirmation : c'est
/// l'utilisateur qui les a créées en langage naturel, il ne faut pas les
/// perdre d'un tap accidentel.
Future<void> _confirmAutomationDelete(
  BuildContext context,
  String title,
  Future<void> Function() onConfirm,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
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
  if (confirmed == true) await onConfirm();
}
