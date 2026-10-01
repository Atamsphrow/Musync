/// The "Importer les paramètres" action of the Settings screen.
///
/// Picks a JSON file written by the export, shows what it holds, and applies
/// it after confirmation. The settings tabs reload from disk afterwards, and
/// the bubble picks up its line count straight away.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/bubble/providers/bubble_provider.dart';
import 'package:musync/features/settings/data/settings_import.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';
import 'package:musync/features/settings/providers/playback_settings_provider.dart';
import 'package:musync/features/settings/providers/settings_provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Human labels for the files of a bundle.
const Map<String, String> _fileLabels = {
  'playback_settings.json': 'Lecture',
  'ai_providers.json': 'Fournisseurs IA',
  'lyrics_sources.json': 'Sources de paroles',
};

Future<void> importSettings(BuildContext context) async {
  final chosen = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['json'],
    dialogTitle: 'Choisir un export Musync',
  );
  final path = chosen?.path;
  final fileName = chosen?.name ?? 'export.json';
  if (path == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final importer = SettingsImporter(
    supportDir: await getApplicationSupportDirectory(),
    documentsDir: await getApplicationDocumentsDirectory(),
  );

  final ImportBundle bundle;
  try {
    bundle = await importer.parse(File(path));
  } on ImportFormatException catch (error) {
    messenger.showOnly(SnackBar(content: Text(error.message)));
    return;
  } catch (error, stack) {
    DebugLog.instance.error(
      'Import',
      'Lecture du fichier impossible',
      error: error,
      stackTrace: stack,
    );
    messenger.showOnly(const SnackBar(content: Text('Fichier illisible.')));
    return;
  }
  if (!context.mounted) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _ImportConfirmDialog(bundle: bundle, fileName: fileName),
  );
  if (confirmed != true || !context.mounted) return;

  try {
    final prefs = await SharedPreferences.getInstance();
    final report = await importer.apply(bundle, prefs);
    if (!context.mounted) return;

    final container = ProviderScope.containerOf(context);
    container
      ..invalidate(lyricsSourcesProvider)
      ..invalidate(aiSettingsProvider)
      ..invalidate(playbackSettingsProvider);
    // The bubble reads its line count at start; applying it live too keeps a
    // visible bubble in sync instead of waiting for its next start.
    final lines = report.appliedPreferences.contains('bubble_lines')
        ? bundle.preferences['bubble_lines']
        : null;
    if (lines is int) {
      await container.read(lyricsBubbleProvider.notifier).setLines(lines);
    }

    messenger.showOnly(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(_summary(report)),
      ),
    );
  } catch (error, stack) {
    DebugLog.instance.error(
      'Import',
      'Application de l\u2019import impossible',
      error: error,
      stackTrace: stack,
    );
    messenger.showOnly(
      const SnackBar(content: Text('Import impossible. Voir le Journal.')),
    );
  }
}

String _summary(ImportReport report) {
  final parts = [
    for (final file in report.appliedFiles) _fileLabels[file] ?? file,
    if (report.appliedPreferences.contains('bubble_lines')) 'Bulle flottante',
    if (report.appliedPreferences.contains('last_song_path')) 'Dernier morceau',
  ];
  var text = 'Importé : ${parts.join(', ')}.';
  if (report.secretsApplied > 0) {
    text +=
        ' ${_plural(report.secretsApplied, 'clé API appliquée', 'clés API appliquées')}.';
  } else if (report.secretsKept > 0) {
    text += ' Clés API déjà configurées conservées.';
  }
  return text;
}

String _plural(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';

class _ImportConfirmDialog extends StatelessWidget {
  final ImportBundle bundle;
  final String fileName;

  const _ImportConfirmDialog({required this.bundle, required this.fileName});

  @override
  Widget build(BuildContext context) {
    final contents = [
      for (final file in bundle.files.keys) _fileLabels[file] ?? file,
      for (final entry in bundle.preferences.entries)
        if (entry.key == 'bubble_lines')
          'Bulle flottante : ${entry.value} lignes',
      if (bundle.preferences.containsKey('last_song_path')) 'Dernier morceau',
    ];
    return AlertDialog(
      title: const Text('Importer les paramètres'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fileName,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          if (bundle.exportedAt.isNotEmpty)
            Text(
              'Exporté le ${_formatDate(bundle.exportedAt)}'
              '${bundle.version.isNotEmpty ? ' · v${bundle.version}' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          Text('Contenu : ${contents.join(', ')}.'),
          if (bundle.ignoredFiles.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Ignoré (non reconnu) : ${bundle.ignoredFiles.join(', ')}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            bundle.includesSecrets
                ? 'Le fichier contient des clés API : elles seront appliquées.'
                : 'Le fichier ne contient pas de clés API : celles déjà '
                    'configurées sont conservées.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Les réglages actuels seront remplacés.',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Importer'),
        ),
      ],
    );
  }
}

String _formatDate(String iso) {
  final dateTime = DateTime.tryParse(iso)?.toLocal();
  if (dateTime == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dateTime.day)}/${two(dateTime.month)}/${dateTime.year} '
      '${two(dateTime.hour)}:${two(dateTime.minute)}';
}
