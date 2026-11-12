import 'package:flutter/material.dart';
import 'package:musync/features/lyrics/data/genius_meaning.dart';

/// Opens the Genius meaning sheet for one line: the line's explanation
/// when Genius annotated it, then the song's "About" text.
///
/// The meaning is fetched on demand — no prefetch, no background
/// traffic for a song the user never asks about — and shown in its
/// original language: machine translation was refused on 2026-11-12.
Future<void> showMeaningSheet(
  BuildContext context, {
  required String title,
  required String artist,
  required String lineText,
  GeniusMeaningService? service,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _MeaningSheet(
      title: title,
      artist: artist,
      lineText: lineText,
      service: service ?? GeniusMeaningService(),
    ),
  );
}

class _MeaningSheet extends StatefulWidget {
  final String title;
  final String artist;
  final String lineText;
  final GeniusMeaningService service;

  const _MeaningSheet({
    required this.title,
    required this.artist,
    required this.lineText,
    required this.service,
  });

  @override
  State<_MeaningSheet> createState() => _MeaningSheetState();
}

class _MeaningSheetState extends State<_MeaningSheet> {
  late Future<GeniusMeaning?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.service.find(
      title: widget.title,
      artist: widget.artist,
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '« ${widget.lineText.trim()} »',
              textAlign: TextAlign.center,
              style: textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.artist} — ${widget.title}',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: FutureBuilder<GeniusMeaning?>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState ==
                        ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError) {
                      return Column(
                        children: [
                          Text(
                            snapshot.error.toString(),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          FilledButton.tonalIcon(
                            onPressed: () => setState(() {
                              _future = widget.service.find(
                                title: widget.title,
                                artist: widget.artist,
                              );
                            }),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Réessayer'),
                          ),
                        ],
                      );
                    }
                    final meaning = snapshot.data;
                    if (meaning == null) {
                      return const Text(
                        'Aucune signification trouvée sur Genius pour ce morceau.',
                        textAlign: TextAlign.center,
                      );
                    }
                    final note = meaning.noteForLine(widget.lineText);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (note != null) ...[
                          Text(
                            note.explanation,
                            style: textTheme.bodyLarge,
                          ),
                          if (note.votes > 0) ...[
                            const SizedBox(height: 8),
                            Text(
                              '${note.votes} vote${note.votes > 1 ? 's' : ''} sur Genius',
                              style: textTheme.bodySmall?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                        ] else ...[
                          const Text(
                            'Genius n’a pas annoté cette ligne.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (meaning.about != null) ...[
                          Text(
                            'À propos',
                            style: textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            meaning.about!,
                            style: textTheme.bodyMedium,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
