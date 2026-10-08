/// Bugs appareil : matching des morceaux (A) et confirmation sur introuvable
/// (B), plus les outils close_app / toggle_bubble.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/ai_tool_registry.dart';
import 'package:musync/features/ai_assistant/data/assistant_bridge.dart';
import 'package:musync/features/ai_assistant/data/tools/file_tools.dart';
import 'package:musync/features/ai_assistant/data/tools/settings_tools.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';

Song _song(int id, String title, String artist) => Song(
      id: id,
      title: title,
      artist: artist,
      album: '',
      duration: 180000,
      filePath: '/musique/$id.mp3',
    );

final _library = [
  _song(1, 'Lean Wit Me', 'Juice WRLD'),
  _song(2, 'Lucid Dreams', 'Juice WRLD'),
  _song(3, 'Bad Energy', 'Juice WRLD'),
  _song(4, 'Me, Myself & I', 'G-Eazy'),
];

AiToolContext _ctx(Ref ref) => AiToolContext(
      ref: ref,
      runTool: (_, _) async => AiToolResult.fail('non'),
      hasTool: (_) => false,
      requiresConfirmation: (_) => false,
    );

final _refProbe = Provider<Ref>((ref) => ref);

class _FakeSongList extends SongListNotifier {
  @override
  Future<List<Song>> build() async => _library;
}

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      songListProvider.overrideWith(_FakeSongList.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('Bug A — matching identique à la recherche bibliothèque', () {
    test('« Juice WRLD lean wit me » trouve « Lean Wit Me »', () {
      final hits = matchSongs(_library, 'Juice WRLD lean wit me');
      expect(hits, isNotEmpty);
      expect(hits.first.title, 'Lean Wit Me');
      expect(hits.first.artist, 'Juice WRLD');
    });

    test('la sous-chaîne exacte reste classée première', () {
      // « lean wit me » matche le n°1 en sous-chaîne exacte ; un autre
      // morceau contenant les mêmes mots dans le désordre passe après.
      final songs = [
        _song(1, 'Wit Me Lean', 'Juice'),
        _song(2, 'Lean Wit Me', 'Juice WRLD'),
      ];
      final hits = matchSongs(songs, 'lean wit me');
      expect(hits.first.id, 2);
    });

    test('pliage accents/casse comme la recherche', () {
      final songs = [_song(1, 'Café del Mar', 'Énergie')];
      expect(matchSongs(songs, 'cafe'), hasLength(1));
      expect(matchSongs(songs, 'ENERGIE'), hasLength(1));
    });

    test('requête vide → rien, comme la recherche', () {
      expect(matchSongs(_library, '   '), isEmpty);
    });

    test('aucun mot en commun → rien', () {
      expect(matchSongs(_library, 'mozart requiem'), isEmpty);
    });
  });

  group('Bug B — jamais de confirmation si la cible n’est pas résolue', () {
    test('delete_file.describeAction lève sur introuvable', () async {
      final ctx = _ctx(_container().read(_refProbe));
      await expectLater(
        () => const DeleteFileTool().describeAction(
          ctx,
          {'query': 'morceau qui n’existe pas du tout'},
        ),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('edit_tags.describeAction lève sur introuvable', () async {
      final ctx = _ctx(_container().read(_refProbe));
      await expectLater(
        () => const EditTagsTool().describeAction(
          ctx,
          {'query': 'morceau qui n’existe pas du tout', 'title': 'X'},
        ),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('le message nomme la requête', () async {
      final ctx = _ctx(_container().read(_refProbe));
      try {
        await const DeleteFileTool().describeAction(
          ctx,
          {'query': 'fahatanorana promax'},
        );
        fail('aurait dû lever');
      } on AiToolArgError catch (e) {
        expect(e.message, contains('introuvable'));
        expect(e.message, contains('fahatanorana promax'));
      }
    });

    test('cible résolue → describeAction décrit, ne lève pas', () async {
      final ctx = _ctx(_container().read(_refProbe));
      final preview = await const DeleteFileTool().describeAction(
        ctx,
        {'query': 'lean wit me'},
      );
      expect(preview, contains('Supprimer DÉFINITIVEMENT'));
      expect(preview, contains('Lean Wit Me'));
    });
  });

  group('close_app / toggle_bubble', () {
    test('enregistrés, sans confirmation', () {
      final registry = buildAiToolRegistry();
      for (final name in ['close_app', 'toggle_bubble']) {
        expect(registry.contains(name), isTrue, reason: name);
        expect(registry[name]!.requiresConfirmation, isFalse, reason: name);
      }
    });

    test('le prompt documente les deux', () {
      final prompt = AssistantBridge.systemPrompt(
        buildAiToolRegistry().describeForLlm(),
      );
      expect(prompt, contains('close_app'));
      expect(prompt, contains('toggle_bubble'));
      expect(prompt, contains('schedule_daily'));
    });

    test('app_help connaît la vraie procédure bulle', () async {
      final ctx = _ctx(_container().read(_refProbe));
      final result = await const AppHelpTool().execute(
        ctx,
        {'question': 'comment activer la bulle ?'},
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('Lecture en cours'));
      // Pas la procédure hallucinée vue sur appareil (« va dans les
      // paramètres… pour autoriser la superposition »).
      expect(result.message, isNot(contains('autoriser la superposition')));
    });
  });
}
