/// The "Exporter les paramètres" action of the Settings screen.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/settings/data/settings_export.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferences worth carrying to another install. The last-played track and its
/// position are left out: they are about this phone's files.
const List<String> _exportedPreferences = ['bubble_lines'];

/// Asks what to include, writes the file and says where it went.
Future<void> exportSettings(BuildContext context) async {
  final includeSecrets = await showDialog<bool>(
    context: context,
    builder: (_) => const _ExportDialog(),
  );
  // null: cancelled.
  if (includeSecrets == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    final prefs = await SharedPreferences.getInstance();
    final exporter = SettingsExporter(
      supportDir: await getApplicationSupportDirectory(),
      documentsDir: await getApplicationDocumentsDirectory(),
    );
    final file = await exporter.exportTo(
      await _targetDir(),
      includeSecrets: includeSecrets,
      preferences: {
        for (final key in _exportedPreferences)
          if (prefs.containsKey(key)) key: prefs.get(key),
      },
    );
    messenger.showOnly(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('Exporté : ${_shortPath(file.path)}'),
      ),
    );
  } catch (error, stack) {
    DebugLog.instance.error(
      'Export',
      'Export des paramètres impossible',
      error: error,
      stackTrace: stack,
    );
    messenger.showOnly(
      const SnackBar(content: Text('Export impossible. Voir le Journal.')),
    );
  }
}

/// The public Downloads folder, where a file can be found from any file
/// manager. Falls back to the app's own external folder when it is not there.
Future<Directory> _targetDir() async {
  final downloads = Directory('/storage/emulated/0/Download');
  if (await downloads.exists()) {
    return Directory('${downloads.path}/Musync');
  }
  final external = await getExternalStorageDirectory();
  return external ?? await getApplicationDocumentsDirectory();
}

String _shortPath(String path) =>
    path.replaceFirst('/storage/emulated/0/', '');

class _ExportDialog extends StatefulWidget {
  const _ExportDialog();

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  bool _secrets = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Exporter les paramètres'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Crée un fichier JSON dans Téléchargements/Musync avec la lecture, '
            'les sources de paroles, les fournisseurs IA et la bulle flottante.',
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _secrets,
            onChanged: (v) => setState(() => _secrets = v ?? false),
            title: const Text('Inclure les clés API'),
            subtitle: const Text(
              'Décoché, elles sont remplacées par du vide. Coché, quiconque '
              'lit le fichier peut les utiliser.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _secrets),
          child: const Text('Exporter'),
        ),
      ],
    );
  }
}
