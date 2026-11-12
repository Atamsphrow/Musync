/// "Try another source": pick one lyrics source and ask it alone.
///
/// The automatic search asks every source and ranks the hits, which is
/// right most of the time — but when it picks wrong, or when a source was
/// set aside and the user knows it is back, this sheet forces one source.
/// A tap asks that source even when it is set aside (the bypass), and the
/// outcome feeds the health like any other search.
///
/// Each row shows what the sheet knows about the source: how many of the
/// current results came from it (and whether any are word-timed), that it
/// already said "no lyrics" for this query, or that it is set aside and
/// for how long. A set-aside row stays tappable — greyed, not disabled.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/lyrics/data/lyrics_source_health.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';

/// Opens the sheet. [title]/[artist] are the query the sheet asks with.
Future<void> showSourcePickerSheet({
  required BuildContext context,
  required String title,
  required String artist,
  String? album,
  int? durationMs,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => _SourcePickerSheet(
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
    ),
  );
}

class _SourcePickerSheet extends ConsumerWidget {
  const _SourcePickerSheet({
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
  });

  final String title;
  final String artist;
  final String? album;
  final int? durationMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final repository = ref.watch(lyricsRepositoryProvider);
    final health = ref.watch(lyricsSourceHealthProvider);
    final results = ref.watch(lyricsSearchResultsProvider);
    final isLoading = ref.watch(lyricsSearchLoadingProvider);
    final trackKey = lyricsHealthTrackKey(title, artist);
    final names = repository.sourceNames;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Essayer une autre source',
                    style: textTheme.titleLarge,
                  ),
                ),
                if (isLoading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Force une source précise quand la recherche automatique '
              'choisit mal. Une source mise de côté peut être forcée.',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: names.length,
                itemBuilder: (context, index) {
                  final name = names[index];
                  final fromSource =
                      results.where((r) => r.source == name).toList();
                  final setAside = health.setAsideRemaining(name);
                  final missing = health.isMissing(trackKey, name);

                  final String subtitle;
                  if (setAside != null) {
                    final minutes = (setAside.inSeconds / 60).ceil();
                    subtitle =
                        'Mise de côté · réessai dans $minutes min — '
                        'toucher pour forcer';
                  } else if (fromSource.isNotEmpty) {
                    final n = fromSource.length;
                    final wordTimed = fromSource.any((r) => r.hasWordTimings);
                    subtitle =
                        '$n résultat${n > 1 ? 's' : ''}'
                        '${wordTimed ? ' · Mot à mot' : ''}';
                  } else if (missing) {
                    subtitle = 'Rien trouvé pour ce morceau';
                  } else {
                    subtitle = 'Aucun résultat pour cette recherche';
                  }

                  return ListTile(
                    leading: Icon(
                      setAside != null ? Icons.cloud_off_outlined : Icons.cloud_outlined,
                      color: setAside != null
                          ? scheme.onSurfaceVariant
                          : scheme.primary,
                    ),
                    title: Text(
                      name,
                      style: setAside != null
                          ? TextStyle(color: scheme.onSurfaceVariant)
                          : null,
                    ),
                    subtitle: Text(subtitle),
                    trailing: fromSource.any((r) => r.hasWordTimings)
                        ? Chip(
                            label: const Text('Mot à mot'),
                            backgroundColor: scheme.tertiaryContainer,
                            labelStyle: textTheme.labelSmall?.copyWith(
                              color: scheme.onTertiaryContainer,
                            ),
                            side: BorderSide.none,
                          )
                        : null,
                    onTap: isLoading
                        ? null
                        : () => _askOne(context, ref, name),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _askOne(
    BuildContext context,
    WidgetRef ref,
    String sourceName,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final found = await performLyricsSearch(
      ref,
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
      explicit: true,
      sourceName: sourceName,
    );
    if (!context.mounted) return;
    final error = ref.read(lyricsSearchErrorProvider);
    if (error != null) {
      messenger.showOnly(
        SnackBar(content: Text(error), duration: const Duration(seconds: 6)),
      );
      return;
    }
    if (found.isEmpty) {
      messenger.showOnly(
        SnackBar(
          content: Text('$sourceName n’a rien trouvé pour ce morceau.'),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    Navigator.pop(context);
  }
}
