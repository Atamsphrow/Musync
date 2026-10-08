/// Le registre : tous les verbes de l'assistant, et la doc générée pour le LLM.
///
/// Ajouter un outil, c'est l'ajouter à [buildAiToolRegistry] — le prompt
/// système (T2) se construit seul à partir d'ici.
library;

import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/tools/file_tools.dart';
import 'package:musync/features/ai_assistant/data/tools/folder_tools.dart';
import 'package:musync/features/ai_assistant/data/tools/song_exclusion_tools.dart';
import 'package:musync/features/ai_assistant/data/tools/library_tools.dart';
import 'package:musync/features/ai_assistant/data/tools/lyrics_tools.dart';
import 'package:musync/features/ai_assistant/data/tools/playback_tools.dart';
import 'package:musync/features/ai_assistant/data/tools/settings_tools.dart';
import 'package:musync/features/ai_assistant/data/tools/timer_tools.dart';
import 'package:musync/features/ai_assistant/data/tools/automation_tools.dart';

class AiToolRegistry {
  final Map<String, AiTool> _byName;

  AiToolRegistry(Iterable<AiTool> tools)
      : _byName = {for (final t in tools) t.name: t};

  AiTool? operator [](String name) => _byName[name];

  bool contains(String name) => _byName.containsKey(name);

  Iterable<String> get names => _byName.keys;

  int get length => _byName.length;

  /// La section « outils » du prompt système : un tiret par outil, avec ses
  /// arguments. Le LLM n'a que ça pour décider.
  String describeForLlm() {
    final out = StringBuffer();
    for (final tool in _byName.values) {
      out.writeln('- ${tool.name}: ${tool.description}');
      out.writeln('  Args: ${_schemaLine(tool.parametersSchema)}'
          '${tool.requiresConfirmation ? '  [CONFIRMATION REQUISE]' : ''}');
    }
    return out.toString();
  }

  static String _schemaLine(Map<String, Object?> schema) {
    final props = schema['properties'];
    if (props is! Map || props.isEmpty) return '{}';
    return '{${props.entries.map((e) => '"${e.key}": ${e.value}').join(', ')}}';
  }
}

AiToolRegistry buildAiToolRegistry() => AiToolRegistry([
      // Lecture
      const PlayTool(),
      const PauseTool(),
      const NextTool(),
      const PreviousTool(),
      const ToggleShuffleTool(),
      const CycleRepeatTool(),
      // Bibliothèque
      const SearchLibraryTool(),
      const PlayArtistShuffledTool(),
      const LibraryStatsTool(),
      const FindDuplicatesTool(),
      const CreateNamedQueueTool(),
      // Paroles
      const FetchLyricsTool(),
      const PrepareLyricsForSyncTool(),
      const AdjustLyricsOffsetTool(),
      const BatchFetchLyricsTool(),
      // Minuteur et planification
      const SleepTimerTool(),
      ScheduleActionTool(),
      // Automatisations (phase 2 : survivent à l'app tuée et au reboot)
      const ScheduleOnceTool(),
      const ScheduleDailyTool(),
      const ListScheduledActionsTool(),
      const CancelScheduledActionTool(),
      const SetHeadphoneTriggerTool(),
      const ClearHeadphoneTriggerTool(),
      // Réglages et aide
      const SetAppearanceTool(),
      const AppHelpTool(),
      const CloseAppTool(),
      const ToggleBubbleTool(),
      // Fichiers (confirmations systématiques)
      const EditTagsTool(),
      const DeleteFileTool(),
      const FixTagsFromFilenameTool(),
      // Dossiers exclus
      const ExcludeFolderTool(),
      const IncludeFolderTool(),
      const ListExcludedFoldersTool(),
      // Fichiers exclus
      const ExcludeSongTool(),
      const IncludeSongTool(),
      const ListExcludedSongsTool(),
    ]);
