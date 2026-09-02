import 'package:flutter/material.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/lyrics/ui/embed_lyrics_action.dart';

/// Online lyrics lookup (plan §3.4).
///
/// Seeded from the file's own tags and searched immediately, since that is
/// right most of the time; the fields stay editable for the files whose tags
/// are wrong, which is the case the plan calls out.
class LyricsSearchScreen extends ConsumerStatefulWidget {
  final Song song;

  const LyricsSearchScreen({super.key, required this.song});

  @override
  ConsumerState<LyricsSearchScreen> createState() => _LyricsSearchScreenState();
}

class _LyricsSearchScreenState extends ConsumerState<LyricsSearchScreen> {
  late final TextEditingController _titleController = TextEditingController(
    text: widget.song.title,
  );
  late final TextEditingController _artistController = TextEditingController(
    text: widget.song.artist,
  );

  /// True while a model is being asked. It can take a few seconds, and a
  /// button that looks idle invites a second press.
  bool _guessing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  /// Rewrites the two fields from what the file is called.
  ///
  /// For the common case where the tags are wrong — a library built from
  /// downloads is full of tracks whose artist is "Unknown" and whose title is
  /// the whole file name, decoration and all — while the name itself says
  /// perfectly clearly who and what.
  ///
  /// Only the fields are touched. Nothing reaches the file until the user picks
  /// a result, so a wrong guess costs one correction, not a bad tag.
  Future<void> _fillFromFilename() async {
    final messenger = ScaffoldMessenger.of(context);

    // The heuristic first, always. It costs nothing, needs no network, and is
    // right on the regular shapes — so it is both the answer and the fallback.
    var guess = FilenameParser.parse(widget.song.filePath);
    // Which model answered, or null when the heuristic's answer is the one being
    // shown. Named rather than a bare flag because with a fallback chain the
    // provider that answered is not necessarily the first one configured.
    String? answeredBy;

    final settings = ref.read(aiSettingsProvider).valueOrNull;
    final resolver = ref.read(aiFilenameResolverProvider);
    final statuses = ref.read(aiProviderStatusProvider.notifier);

    if (settings != null && settings.usable.isNotEmpty) {
      setState(() => _guessing = true);
      // Every configured model in turn, stopping at the first that answers.
      // One broken provider no longer takes the feature down with it, and no
      // longer produces a snackbar on every press — the intermediate failures
      // go to the log, and the user hears about it only if none of them work.
      final resolution = await resolver.resolve(
        settings: settings,
        fileName: widget.song.filePath.split(RegExp(r'[/\\]')).last,
      );
      // Feeds the per-provider indicators in Paramètres › IA, so the answer to
      // "which of my keys works" lives next to the keys.
      statuses.recordAttempts(resolution.attempts);

      if (resolution.answered) {
        guess = resolution.guess!;
        answeredBy = resolution.providerName;
      } else if (resolution.allFailed) {
        // The heuristic's answer still goes into the fields below; this only
        // says why the model did not get a say.
        messenger.showOnly(
          SnackBar(
            content: Text(
              'Aucun modèle n\'a répondu. Analyse locale utilisée. '
              '${resolution.failureSummary}',
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }

      if (mounted) setState(() => _guessing = false);
    }

    if (!mounted) return;

    if (guess.title.isEmpty && guess.artist.isEmpty) {
      messenger.showOnly(
        const SnackBar(
          content: Text('Le nom du fichier ne dit rien d’exploitable.'),
        ),
      );
      return;
    }

    setState(() {
      if (guess.title.isNotEmpty) _titleController.text = guess.title;
      if (guess.artist.isNotEmpty) _artistController.text = guess.artist;
    });

    // Said out loud, because the fields may have been right already and the
    // user needs to see that something happened — and where it came from.
    final source = answeredBy == null ? '' : '$answeredBy : ';
    messenger.showOnly(
      SnackBar(
        content: Text(
          guess.artist.isEmpty
              ? '${source}titre deviné, pas d’artiste dans le nom.'
              : '$source${guess.artist} — ${guess.title}',
        ),
      ),
    );
  }

  void _search() {
    performLyricsSearch(
      ref,
      title: _titleController.text,
      artist: _artistController.text,
      album: widget.song.album,
      durationMs: widget.song.duration,
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(lyricsSearchResultsProvider);
    final isLoading = ref.watch(lyricsSearchLoadingProvider);
    final error = ref.watch(lyricsSearchErrorProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Rechercher des paroles')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                _ClearableField(
                  controller: _titleController,
                  label: 'Titre',
                  icon: Icons.music_note,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                _ClearableField(
                  controller: _artistController,
                  label: 'Artiste',
                  icon: Icons.person_outline,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _guessing ? null : _fillFromFilename,
                    icon: _guessing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high, size: 18),
                    label: Text(
                      _guessing
                          ? 'Le modèle réfléchit…'
                          : 'Deviner depuis le nom du fichier',
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: isLoading ? null : _search,
                    icon: const Icon(Icons.search, size: 18),
                    label: Text(isLoading ? 'Recherche…' : 'Rechercher'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(child: _buildResults(isLoading, error, results)),
        ],
      ),
    );
  }

  Widget _buildResults(
    bool isLoading,
    String? error,
    List<LyricsSearchResult> results,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (isLoading) return const Center(child: CircularProgressIndicator());

    if (error != null) {
      return _Message(
        icon: Icons.cloud_off,
        title: 'Recherche impossible',
        message: error,
        action: FilledButton.icon(
          onPressed: _search,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Réessayer'),
        ),
      );
    }

    if (results.isEmpty) {
      return const _Message(
        icon: Icons.search_off,
        title: 'Aucun résultat',
        message:
            'Vérifiez le titre et l\'artiste, puis relancez la recherche. '
            'Les tags du fichier sont parfois incomplets.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final result = results[index];
        return Card(
          child: ListTile(
            title: Text(
              result.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${result.artist} • ${result.source}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Chip(
              label: Text(result.hasSyncedLyrics ? 'Synchro' : 'Texte'),
              // Synced results are what the app is for, so they are the ones
              // that get the accent.
              backgroundColor: result.hasSyncedLyrics
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              labelStyle: textTheme.labelSmall?.copyWith(
                color: result.hasSyncedLyrics
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
              side: BorderSide.none,
            ),
            onTap: () => _preview(result),
          ),
        );
      },
    );
  }

  void _preview(LyricsSearchResult result) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _PreviewSheet(
        result: result,
        onEmbed: () => _embed(sheetContext, result),
      ),
    );
  }

  Future<void> _embed(
    BuildContext sheetContext,
    LyricsSearchResult result,
  ) async {
    // One message, not two.
    //
    // This screen used to show its own confirmation on top of the one
    // `embedLyrics` shows, so picking a result produced two stacked banners
    // saying much the same thing — and the second hid the first's action.
    // The wording is handed over instead; the undo comes with it.
    //
    // The "Ajuster" shortcut that used to live here is the casualty: a snackbar
    // carries one action, and between adjusting timings and undoing a write to
    // the user's own file, the way back matters more. The sync editor is still
    // one tap away from the player.
    final outcome = await embedLyrics(
      context,
      ref,
      filePath: widget.song.filePath,
      synced: result.syncedLyrics,
      unsynced: result.unsyncedLyrics,
      successMessage: result.hasSyncedLyrics
          ? '${result.syncedLyrics!.length} lignes calées enregistrées.'
          : 'Paroles enregistrées dans le fichier.',
    );
    if (outcome != EmbedOutcome.written || !mounted) return;

    if (sheetContext.mounted) Navigator.pop(sheetContext);
    if (!mounted) return;

    Navigator.pop(context);
  }
}

class _PreviewSheet extends StatelessWidget {
  final LyricsSearchResult result;
  final VoidCallback onEmbed;

  const _PreviewSheet({required this.result, required this.onEmbed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final body = result.hasSyncedLyrics
        ? result.syncedLyrics!.toLrc()
        : (result.unsyncedLyrics?.text ?? '');

    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.title, style: textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(
                  '${result.artist}${result.album != null ? ' • ${result.album}' : ''}',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SelectableText(
                body,
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onEmbed,
                icon: const Icon(Icons.download_done, size: 18),
                label: const Text('Enregistrer dans le fichier'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const _Message({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}

/// A text field with a clear button (plan P6).
///
/// The button appears only once there is something to clear, so an empty form
/// isn't cluttered with two dead crosses. It watches the controller rather than
/// keeping its own copy of the text: one source of truth, and no listener to
/// register and tear down by hand.
class _ClearableField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  const _ClearableField({
    required this.controller,
    required this.label,
    required this.icon,
    required this.textInputAction,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Effacer',
                  onPressed: controller.clear,
                ),
        ),
      ),
    );
  }
}
