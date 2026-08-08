import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/core/router/app_router.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
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
  late final TextEditingController _titleController =
      TextEditingController(text: widget.song.title);
  late final TextEditingController _artistController =
      TextEditingController(text: widget.song.artist);

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
                TextField(
                  controller: _titleController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Titre',
                    prefixIcon: Icon(Icons.music_note),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _artistController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    labelText: 'Artiste',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 16),
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
        message: 'Vérifiez le titre et l\'artiste, puis relancez la recherche. '
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
            title: Text(result.title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
    final saved = await embedLyrics(
      context,
      ref,
      filePath: widget.song.filePath,
      synced: result.syncedLyrics,
      unsynced: result.unsyncedLyrics,
    );
    if (!saved || !mounted) return;

    if (sheetContext.mounted) Navigator.pop(sheetContext);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Paroles enregistrées dans le fichier.'),
        // Timing is the natural next step for a synced result, so offer it
        // instead of making the user walk back through the player.
        action: result.hasSyncedLyrics
            ? SnackBarAction(
                label: 'Ajuster',
                onPressed: () => Navigator.pushNamed(
                  context,
                  AppRoutes.syncEditor,
                  arguments: SongRouteArgs(song: widget.song),
                ),
              )
            : null,
      ),
    );
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
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
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
                style: textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
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
              style: textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}
