/// Tests des outils d'exclusion au niveau fichier (T5 révisé).
///
/// « Exclus ce morceau » cache exactement ce fichier-là, le reste de son
/// dossier n'est pas touché.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/ai_tool_registry.dart';
import 'package:musync/features/ai_assistant/data/tools/song_exclusion_tools.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/settings/providers/excluded_files_provider.dart';
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
    requiresConfirmation: (_) => false,
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
    test('les trois outils fichiers sont enregistrés', () {
      final registry = buildAiToolRegistry();
      expect(registry.contains('exclude_song'), isTrue);
      expect(registry.contains('include_song'), isTrue);
      expect(registry.contains('list_excluded_songs'), isTrue);
    });

    test('exclude_song exige une confirmation, pas les deux autres', () {
      expect(const ExcludeSongTool().requiresConfirmation, isTrue);
      expect(const IncludeSongTool().requiresConfirmation, isFalse);
      expect(const ListExcludedSongsTool().requiresConfirmation, isFalse);
    });
  });

  group('exclude_song', () {
    test('la confirmation nomme le fichier exact, dossier non touché', () async {
      final container = _container();
      const tool = ExcludeSongTool();
      final preview = await tool.describeAction(
        _ctx(container),
        {'path': '/storage/Music/Clips/tiko.mp3'},
      );
      expect(preview, contains('/storage/Music/Clips/tiko.mp3'));
      expect(preview, contains('le reste du dossier n’est pas touché'));
    });

    test('exécute : le fichier rejoint la liste des exclus', () async {
      final container = _container();
      const tool = ExcludeSongTool();
      final result = await tool.execute(
        _ctx(container),
        {'path': '/storage/Music/Clips/tiko.mp3'},
      );
      expect(result.ok, isTrue);
      expect(
        await container.read(excludedFilesProvider.future),
        ['/storage/Music/Clips/tiko.mp3'],
      );
    });

    test('query : exclut le fichier du morceau trouvé, pas son dossier',
        () async {
      final container = _container(
        songs: [_song('Tiko Enao', 'Artiste', '/storage/Music/Clips/tiko.mp3')],
      );
      const tool = ExcludeSongTool();
      final result = await tool.execute(
        _ctx(container),
        {'query': 'tiko'},
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('/storage/Music/Clips/tiko.mp3'));
      expect(
        await container.read(excludedFilesProvider.future),
        ['/storage/Music/Clips/tiko.mp3'],
      );
    });

    test('query sans résultat : erreur d’argument claire', () async {
      final container = _container();
      const tool = ExcludeSongTool();
      await expectLater(
        () =>
            tool.execute(_ctx(container), {'query': 'morceau-qui-nexiste-pas'}),
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

  group('include_song', () {
    test('retire le fichier de la liste', () async {
      final container = _container();
      await container
          .read(excludedFilesProvider.notifier)
          .add('/storage/Music/Clips/tiko.mp3');
      const tool = IncludeSongTool();
      final result = await tool.execute(
        _ctx(container),
        {'path': '/storage/Music/Clips/tiko.mp3'},
      );
      expect(result.ok, isTrue);
      expect(await container.read(excludedFilesProvider.future), isEmpty);
    });
  });

  group('list_excluded_songs', () {
    test('liste vide : message explicite', () async {
      final container = _container();
      final result = await const ListExcludedSongsTool().execute(
        _ctx(container),
        {},
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('Aucun fichier exclu'));
    });

    test('liste les fichiers exclus', () async {
      final container = _container();
      final notifier = container.read(excludedFilesProvider.notifier);
      await notifier.add('/storage/Music/a.mp3');
      await notifier.add('/storage/Music/b.mp3');
      final result = await const ListExcludedSongsTool().execute(
        _ctx(container),
        {},
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('/storage/Music/a.mp3'));
      expect(result.message, contains('/storage/Music/b.mp3'));
    });
  });
}
