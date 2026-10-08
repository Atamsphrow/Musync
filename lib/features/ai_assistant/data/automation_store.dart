/// Persistance des automatisations : actions planifiées + déclencheur écouteurs.
///
/// Un seul fichier JSON atomique (`automations.json`), même pattern que les
/// autres stores de l'app. Le côté natif (alarmes, boot) ne lit JAMAIS ce
/// fichier : Dart lui pousse un miroir via le canal `scheduler`
/// (`syncAlarms`), et ce miroir est la seule chose que le natif réarme.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/utils/atomic_file.dart';
import 'package:musync/features/ai_assistant/data/automation.dart';
import 'package:path_provider/path_provider.dart';

/// L'état complet des automatisations.
class AutomationsDoc {
  final List<ScheduledAction> actions;
  final HeadphoneTrigger? headphoneTrigger;

  const AutomationsDoc({this.actions = const [], this.headphoneTrigger});

  Map<String, Object?> toJson() => {
        'actions': [for (final a in actions) a.toJson()],
        if (headphoneTrigger != null) 'headphoneTrigger': headphoneTrigger!.toJson(),
      };

  static AutomationsDoc fromJson(Object? json) {
    if (json is! Map) return const AutomationsDoc();
    final rawActions = json['actions'];
    return AutomationsDoc(
      actions: [
        if (rawActions is List)
          for (final e in rawActions)
            ?ScheduledAction.fromJson(e),
      ],
      headphoneTrigger: HeadphoneTrigger.fromJson(json['headphoneTrigger']),
    );
  }
}

class AutomationStore {
  static const String _fileName = 'automations.json';

  /// Where the file lives. Production reads the app's documents directory;
  /// tests inject a temporary file instead — `path_provider` has no plugin
  /// in a unit test.
  final Future<File> Function()? fileLocator;

  const AutomationStore({this.fileLocator});

  Future<File> _file() async {
    final locator = fileLocator;
    if (locator != null) return locator();
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// Jamais d'exception : un fichier illisible = pas d'automatisations, et
  /// l'app continue de marcher.
  Future<AutomationsDoc> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const AutomationsDoc();
      return AutomationsDoc.fromJson(jsonDecode(await file.readAsString()));
    } catch (error, stack) {
      DebugLog.instance.error(
        'Automatisations',
        'Automatisations illisibles : ignorées',
        error: error,
        stackTrace: stack,
      );
      return const AutomationsDoc();
    }
  }

  /// Écriture atomique, sérialisée par fichier — voir [AtomicFile].
  Future<void> save(AutomationsDoc doc) async {
    await AtomicFile.writeString(
      await _file(),
      jsonEncode(doc.toJson()),
    );
  }

  @visibleForTesting
  static AutomationsDoc docForTest(AutomationsDoc doc) => doc;
}
