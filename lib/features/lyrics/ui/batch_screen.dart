/// Search a whole tab's worth of tracks, look at what came back, then write.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/providers/batch_provider.dart';
import 'package:musync/features/lyrics/ui/embed_lyrics_action.dart';

class BatchScreen extends ConsumerStatefulWidget {
  final List<Song> songs;

  const BatchScreen({super.key, required this.songs});

  @override
  ConsumerState<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends ConsumerState<BatchScreen> {
  /// Tracks left alone because they already had timed lyrics.
  ///
  /// Kept on the screen rather than in the batch state: it describes one press
  /// of "Écrire", not the batch, and it must reset when the user tries again
  /// after unticking the rows in question.
  int _kept = 0;

  /// Held from initState rather than read in dispose.
  ///
  /// `ref` belongs to the widget, and reaching for it while the widget is being
  /// taken down is how "Cannot use ref after the widget was disposed" happens —
  /// the same fault the debug panel caught on the search screen. The notifier
  /// itself outlives this screen, so keeping the reference is safe where
  /// keeping the `ref` is not.
  late final BatchNotifier _batch;

  @override
  void initState() {
    super.initState();
    _batch = ref.read(batchProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _batch.start(widget.songs);
    });
  }

  // No dispose override on purpose.
  //
  // This used to call `_batch.reset()`, on the reasoning that a search with
  // nobody watching it was pointless. That was wrong twice over. The back arrow
  // is not the "Arrêter" button — a scan of several hundred tracks is exactly
  // the thing a user wants to leave running while they do something else — and
  // resetting mid-flight emptied the list the running loop was writing into,
  // which is where the `RangeError` came from.
  //
  // The job now belongs to the notifier, which outlives every screen. Leaving
  // hides the progress; coming back shows it again. Only "Arrêter" stops it,
  // and only "Nouvelle recherche" clears it.

  /// Writes the ticked matches, one at a time.
  ///
  /// Sequentially on purpose. Each write rewrites a file and asks MediaStore to
  /// re-index it; running those in parallel would have several rewrites of
  /// different tracks competing for the same disk to no benefit.
  ///
  /// Every one goes through `embedLyrics`, so each is backed up and individually
  /// undoable from Paramètres › Historique — which is what makes writing to a
  /// hundred tracks a reasonable thing to offer at all.
  Future<void> _writeSelected() async {
    final chosen = ref.read(batchProvider).selected.toList();
    if (chosen.isEmpty) return;

    _kept = 0;
    _batch.beginWriting();

    for (final candidate in chosen) {
      if (!mounted) return;

      // Skip what this session already wrote.
      //
      // Writing needs the screen — the permission prompt and the error messages
      // both need a context — so leaving mid-write still stops it. What it must
      // not do is start over: an interrupted run used to rewrite every track it
      // had already done, which is both slow and a chance to overwrite a good
      // tag with a second, different guess. Pressing "Écrire" again now picks up
      // where it stopped.
      if (_batch.wasWritten(candidate.song.filePath)) continue;

      final match = candidate.match!;

      final outcome = await embedLyrics(
        context,
        ref,
        filePath: candidate.song.filePath,
        synced: match.syncedLyrics,
        unsynced: match.unsyncedLyrics,
        // Skip rather than ask: a dialog per file is not a review, and the
        // answer would be the same every time. A track that already has timed
        // lyrics is left exactly as it was, and counted.
        onPlainOverSynced: PlainOverSynced.skip,
        // No per-track snackbar: a hundred of them stacked up would bury the
        // screen. The summary at the end says what happened.
        successMessage: '',
      );
      if (outcome == EmbedOutcome.written) {
        _batch.recordWritten(candidate.song.filePath);
      } else if (outcome == EmbedOutcome.keptSynced) {
        _kept++;
      }
    }

    if (!mounted) return;
    _batch.finish();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(batchProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recherche par lot'),
        actions: [
          if (state.phase == BatchPhase.searching)
            TextButton(
              onPressed: ref.read(batchProvider.notifier).cancel,
              child: const Text('Arrêter'),
            ),
          // Now that leaving the screen no longer clears the batch, this is the
          // only way to throw one away and look again.
          if (state.phase == BatchPhase.review ||
              state.phase == BatchPhase.done)
            IconButton(
              onPressed: () {
                _batch.reset();
                _batch.start(widget.songs);
              },
              icon: const Icon(Icons.refresh),
              tooltip: 'Nouvelle recherche',
            ),
        ],
      ),
      body: switch (state.phase) {
        BatchPhase.idle || BatchPhase.searching => _Searching(state: state),
        BatchPhase.review => _Review(state: state),
        BatchPhase.writing => _Writing(state: state),
        BatchPhase.done => _Done(state: state, kept: _kept),
      },
      floatingActionButton: state.phase == BatchPhase.review
          ? FloatingActionButton.extended(
              onPressed: state.selected.isEmpty ? null : _writeSelected,
              icon: const Icon(Icons.save_outlined),
              label: Text('Écrire ${state.selected.length}'),
            )
          : null,
    );
  }
}

class _Searching extends StatelessWidget {
  final BatchState state;

  const _Searching({required this.state});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final progress = state.total == 0 ? null : state.done / state.total;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 20),
          Text('${state.done} / ${state.total}', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Rien n\'est écrit pour l\'instant. Vous verrez les résultats avant '
            'de décider.\n\nVous pouvez quitter cet écran : la recherche '
            'continue, et vous la retrouverez ici.',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Text('${state.found.length} trouvé(s)', style: textTheme.labelMedium),
        ],
      ),
    );
  }
}

/// Which slice of the batch the list is showing.
///
/// T13: eighteen hundred rows with the fifty-six useful ones scattered through
/// them is not a review screen, it is a haystack. And the reverse view matters
/// just as much — the failures are the evidence for T12, and until now there
/// was no way to look at them at all.
enum _Filter { found, confident, missing, all }

class _Review extends ConsumerStatefulWidget {
  final BatchState state;

  const _Review({required this.state});

  @override
  ConsumerState<_Review> createState() => _ReviewState();
}

class _ReviewState extends ConsumerState<_Review> {
  late _Filter _filter = widget.state.found.isEmpty
      // Nothing found: open on the failures rather than on an empty list under
      // a filter the user never chose.
      ? _Filter.missing
      : _Filter.found;

  bool _keeps(BatchCandidate candidate) => switch (_filter) {
    _Filter.all => true,
    _Filter.found => candidate.hasMatch,
    _Filter.confident => candidate.isConfident,
    _Filter.missing => !candidate.hasMatch,
  };

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final notifier = ref.read(batchProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final foundCount = state.found.length;
    final confidentCount = state.candidates.where((c) => c.isConfident).length;

    // Indices are carried alongside, because toggling a row addresses it by its
    // position in the whole batch — filtering the list must not renumber it.
    final rows = <(int, BatchCandidate)>[
      for (var i = 0; i < state.candidates.length; i++)
        if (_keeps(state.candidates[i])) (i, state.candidates[i]),
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  foundCount == 0
                      ? "Aucun résultat pour ces ${state.total} morceaux. "
                            "Ouvrez « Sans résultat » pour voir ce qui a été "
                            "cherché."
                      : "$foundCount trouvé(s), ${state.missing} sans "
                            "résultat. Les correspondances sûres sont déjà "
                            "cochées.",
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              PopupMenuButton<_Selection>(
                icon: const Icon(Icons.checklist),
                tooltip: "Sélection",
                onSelected: (choice) => switch (choice) {
                  _Selection.all => notifier.selectAll(selected: true),
                  _Selection.none => notifier.selectAll(selected: false),
                  _Selection.confident => notifier.selectConfidentOnly(),
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _Selection.confident,
                    child: Text("Seulement les sûres"),
                  ),
                  PopupMenuItem(value: _Selection.all, child: Text("Tout")),
                  PopupMenuItem(value: _Selection.none, child: Text("Rien")),
                ],
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<_Filter>(
            segments: [
              ButtonSegment(
                value: _Filter.found,
                label: Text("Trouvés ($foundCount)"),
              ),
              ButtonSegment(
                value: _Filter.confident,
                label: Text("Sûres ($confidentCount)"),
              ),
              ButtonSegment(
                value: _Filter.missing,
                label: Text("Sans résultat (${state.missing})"),
              ),
              ButtonSegment(
                value: _Filter.all,
                label: Text("Tous (${state.candidates.length})"),
              ),
            ],
            selected: {_filter},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (choice) =>
                setState(() => _filter = choice.first),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      "Rien dans cette catégorie.",
                      style: textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: rows.length,
                  itemBuilder: (context, position) => _CandidateTile(
                    index: rows[position].$1,
                    candidate: rows[position].$2,
                  ),
                ),
        ),
      ],
    );
  }
}

enum _Selection { confident, all, none }

class _CandidateTile extends ConsumerWidget {
  final int index;
  final BatchCandidate candidate;

  const _CandidateTile({required this.index, required this.candidate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (!candidate.hasMatch) {
      // What was searched for, not merely that it failed.
      //
      // The whole of T12's second half is "why do 1820 of 1876 miss?", and the
      // answer is usually legible the instant you can see that the app asked
      // for `09` by `<unknown>`. A row saying only "Aucun résultat" leaves that
      // unanswerable without instrumenting a build.
      final queried = candidate.queriedTitle.isEmpty
          ? null
          : "« ${candidate.queriedArtist} — ${candidate.queriedTitle} »";

      return ListTile(
        enabled: false,
        leading: Icon(
          candidate.error == null ? Icons.search_off : Icons.cloud_off,
          color: scheme.onSurfaceVariant,
        ),
        title: Text(candidate.song.title, maxLines: 1),
        subtitle: Text(
          candidate.error ??
              (queried == null
                  ? "Aucun résultat"
                  : "Aucun résultat pour $queried"),
          maxLines: 2,
          style: textTheme.labelSmall,
        ),
        isThreeLine: candidate.error == null && queried != null,
      );
    }

    final match = candidate.match!;
    final confident = match.confidence >= BatchCandidate.autoSelectConfidence;

    return CheckboxListTile(
      value: candidate.selected,
      onChanged: (_) => ref.read(batchProvider.notifier).toggle(index),
      title: Text(
        candidate.song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // What will be written, spelled out. The point of this screen is that
          // the user can see the match is wrong before it reaches a file.
          Text(
            '→ ${match.artist} — ${match.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: scheme.primary),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                match.hasSyncedLyrics ? 'Synchro' : 'Texte',
                style: textTheme.labelSmall?.copyWith(
                  color: match.hasSyncedLyrics
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
              Text(
                candidate.viaFilename
                    ? "  ·  ${match.source}  ·  nom du fichier  ·  "
                    : "  ·  ${match.source}  ·  ",
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              Text(
                confident ? 'sûr' : 'à vérifier',
                style: textTheme.labelSmall?.copyWith(
                  color: confident ? scheme.onSurfaceVariant : scheme.error,
                ),
              ),
            ],
          ),
        ],
      ),
      isThreeLine: true,
    );
  }
}

class _Writing extends StatelessWidget {
  final BatchState state;

  const _Writing({required this.state});

  @override
  Widget build(BuildContext context) {
    final total = state.selected.length;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          LinearProgressIndicator(
            value: total == 0 ? null : state.written / total,
          ),
          const SizedBox(height: 20),
          Text(
            'Écriture ${state.written} / $total',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

/// The summary, which now says *which* tracks and not only how many.
///
/// A bare count left the obvious question unanswerable: the only way to find out
/// what a batch had touched was Paramètres › Historique, which lists every write
/// the app has ever made rather than this run's. With a hundred tracks selected
/// that is not a list anyone can read.
class _Done extends ConsumerWidget {
  final BatchState state;

  /// Tracks left alone because they already had timed lyrics. See
  /// [PlainOverSynced].
  final int kept;

  const _Done({required this.state, required this.kept});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final written = ref.read(batchProvider.notifier).written;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 12),
          child: Column(
            children: [
              Icon(Icons.check_circle_outline, size: 56, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                kept == 0
                    ? "${written.length} morceau(x) écrit(s)."
                    : "${written.length} morceau(x) écrit(s), $kept laissé(s) "
                          "tels quels : ils avaient déjà des paroles calées, "
                          "et le résultat trouvé n'a que du texte.",
                style: textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                'Chacun peut être annulé séparément depuis '
                'Paramètres › Historique.',
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: written.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      "Rien n'a été écrit.",
                      style: textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: written.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final song = written[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(Icons.check, color: scheme.primary),
                      title: Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Terminé'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
