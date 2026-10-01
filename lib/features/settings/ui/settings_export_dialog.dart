/// The "Exporter les paramètres" action of the Settings screen.
library;

import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:musync/features/settings/data/settings_export.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferences worth carrying to another install. The last-played track and its
/// position travel along: on the target phone they re-open the same track when
/// it is there, and are simply ignored when the file does not exist.
const List<String> _exportedPreferences = [
  'bubble_lines',
  'last_song_path',
  'last_song_position_ms',
];

/// Asks what to include, writes the file and says where it went.
///
/// The save goes through the Storage Access Framework (the system file
/// picker), not a hard-coded `/Download` path: on Android 11+ an app cannot
/// write to the shared Downloads folder directly, so the old path failed
/// there. The picker works on every version and needs no permission.
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
    final moment = DateTime.now();
    final bundle = await exporter.build(
      includeSecrets: includeSecrets,
      preferences: {
        for (final key in _exportedPreferences)
          if (prefs.containsKey(key)) key: prefs.get(key),
      },
      now: moment,
    );
    final unreadable = (bundle['unreadable'] as List?)?.cast<String>() ?? const [];
    final tagBackups = bundle['tagBackups'] as Map?;
    final backupCount = (tagBackups?['index'] as List?)?.length ?? 0;
    final backupMissing =
        (tagBackups?['missing'] as List?)?.cast<String>() ?? const [];
    final backupUnreadable =
        (tagBackups?['unreadable'] as List?)?.cast<String>() ?? const [];

    final savedUri = await FilePicker.saveFile(
      dialogTitle: 'Enregistrer l\u2019export Musync',
      fileName: 'musync-export-${_exportStamp(moment)}.json',
      mimeType: 'application/json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: utf8.encode(
        const JsonEncoder.withIndent('  ').convert(bundle),
      ),
    );
    if (savedUri == null) return; // User cancelled the picker.
    if (!context.mounted) return;
    final savedPath = savedUri.toString();

    final problems = [
      if (unreadable.isNotEmpty)
        '${unreadable.length} réglage(s) illisible(s) non inclus : '
            '${unreadable.join(', ')}',
      if (backupMissing.isNotEmpty || backupUnreadable.isNotEmpty)
        '${backupMissing.length + backupUnreadable.length} sauvegarde(s) '
            "d'historique manquante(s)",
    ];
    final history = backupCount == 0
        ? 'sans historique'
        : 'avec $backupCount sauvegarde(s) d’historique';
    final message = problems.isEmpty
        ? 'Exporté ($history) : ${_shortPath(savedPath)}'
        : 'Exporté ($history) : ${_shortPath(savedPath)} '
            '(${problems.join(' ; ')})';
    messenger.showOnly(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(message),
      ),
    );
  } catch (error, stack) {
    DebugLog.instance.error(
      'Export',
      'Export des paramètres impossible',
      error: error,
      stackTrace: stack,
    );
    if (!context.mounted) return;
    messenger.showOnly(
      const SnackBar(content: Text('Export impossible. Voir le Journal.')),
    );
  }
}

String _exportStamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
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
            "les sources de paroles, les fournisseurs IA, la bulle flottante "
            "et l'historique des sauvegardes de tags (pour annuler une "
            'écriture après réinstallation).',
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
