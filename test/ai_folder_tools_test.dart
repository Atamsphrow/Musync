/// Tests des outils « dossiers à exclure » (T5).
///
/// L'assistant pilote `excludedDirsProvider` : exclure un dossier entier
/// (avec confirmation nommant le dossier exact), le réintégrer, lister.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/ai_tool_registry.dart';
import 'package:musync/features/ai_assistant/data/tools/folder_tools.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/settings/providers/excluded_dirs_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String title, String artist, String path) => Song(
      id: path.hashCode,
      title: title,
      artist: artist,
      album: '',
      duration: 180000,
      filePath: path,
    );

class _FixedSongList extends SongListNotifier {
  final List<Song> songs;
  _FixedSongList(this.songs);

  @override
  Future<List<Song>> build() async => songs;
}

AiToolContext _ctx(ProviderContainer container) {
  final ref = container.read(_refProbe);
  return AiToolContext(
    ref: ref,
    runTool: (_, _) async => AiToolResult.fail('non'),
    hasTool: (_) => false,
  );
}

final _refProbe = Provider<Ref>((ref) => ref);

ProviderContainer _container({List<Song> songs = const []}) {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      songListProvider.overrideWith(() => _FixedSongList(songs)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('registre', () {
    test('les trois outils dossiers sont enregistrés', () {
      final registry = buildAiToolRegistry();
      expect(registry.contains('exclude_folder'), isTrue);
      expect(registry.contains('include_folder'), isTrue);
      expect(registry.contains('list_excluded_folders'), isTrue);
    });

    test('exclude_folder exige une confirmation, pas les deux autres', () {
      expect(const ExcludeFolderTool().requiresConfirmation, isTrue);
      expect(const IncludeFolderTool().requiresConfirmation, isFalse);
      expect(const ListExcludedFoldersTool().requiresConfirmation, isFalse);
    });
  });

  group('exclude_folder', () {
    test('la confirmation nomme le dossier exact et tout son contenu', () async {
      final container = _container();
      const tool = ExcludeFolderTool();
      final preview = await tool.describeAction(
        _ctx(container),
        {'path': '/storage/Music/Demo'},
      );
      expect(preview, contains('/storage/Music/Demo'));
      expect(preview, contains('Tout son contenu'));
    });

    test('exécute : le dossier rejoint la liste des exclus', () async {
      final container = _container();
      const tool = ExcludeFolderTool();
      final result = await tool.execute(
        _ctx(container),
        {'path': '/storage/Music/Demo'},
      );
      expect(result.ok, isTrue);
      expect(
        await container.read(excludedDirsProvider.future),
        ['/storage/Music/Demo'],
      );
    });

    test('query : exclut le dossier parent du morceau trouvé', () async {
      final container = _container(
        songs: [_song('Tiko Enao', 'Artiste', '/storage/Music/Clips/tiko.mp3')],
      );
      const tool = ExcludeFolderTool();
      final result = await tool.execute(
        _ctx(container),
        {'query': 'tiko'},
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('/storage/Music/Clips'));
      expect(
        await container.read(excludedDirsProvider.future),
        ['/storage/Music/Clips'],
      );
    });

    test('query sans résultat : erreur d’argument claire', () async {
      final container = _container();
      const tool = ExcludeFolderTool();
      await expectLater(
        () => tool.execute(_ctx(container), {'query': 'morceau-qui-nexiste-pas'}),
        throwsA(
          isA<AiToolArgError>().having(
            (e) => e.message,
            'message',
            contains('Aucun morceau trouvé'),
          ),
        ),
      );
    });
  });

  group('include_folder', () {
    test('retire le dossier de la liste', () async {
      final container = _container();
      await container
          .read(excludedDirsProvider.notifier)
          .add('/storage/Music/Demo');
      const tool = IncludeFolderTool();
      final result = await tool.execute(
        _ctx(container),
        {'path': '/storage/Music/Demo'},
      );
      expect(result.ok, isTrue);
      expect(await container.read(excludedDirsProvider.future), isEmpty);
    });
  });

  group('list_excluded_folders', () {
    test('liste vide : message explicite', () async {
      final container = _container();
      final result = await const ListExcludedFoldersTool().execute(
        _ctx(container),
        {},
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('Aucun dossier exclu'));
    });

    test('liste les dossiers exclus', () async {
      final container = _container();
      final notifier = container.read(excludedDirsProvider.notifier);
      await notifier.add('/storage/Music/Demo');
      await notifier.add('/storage/Podcasts');
      final result = await const ListExcludedFoldersTool().execute(
        _ctx(container),
        {},
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('/storage/Music/Demo'));
      expect(result.message, contains('/storage/Podcasts'));
    });
  });
}
