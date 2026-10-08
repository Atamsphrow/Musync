/// Tests du registre d'outils de l'assistant IA (T1).
///
/// Ne teste que la partie pure : registre, schémas, validation des arguments,
/// recherche locale. L'exécution réelle (Riverpod, fichiers) est couverte par
/// les tests d'intégration de chaque feature.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/ai_tool_registry.dart';
import 'package:musync/features/library/data/models/song.dart';

const _expectedTools = [
  'play',
  'pause',
  'next',
  'previous',
  'toggle_shuffle',
  'cycle_repeat',
  'search_library',
  'play_artist_shuffled',
  'library_stats',
  'create_named_queue',
  'fetch_lyrics',
  'prepare_lyrics_for_sync',
  'adjust_lyrics_offset',
  'batch_fetch_lyrics',
  'sleep_timer',
  'schedule_action',
  'set_appearance',
  'app_help',
  'edit_tags',
  'delete_file',
  'fix_tags_from_filename',
];

/// Les outils destructeurs : confirmation systématique, un fichier à la fois.
const _confirmingTools = {
  'edit_tags',
  'delete_file',
  'fix_tags_from_filename',
  'batch_fetch_lyrics',
};

AiToolContext _ctx(Ref ref) => AiToolContext(
      ref: ref,
      runTool: (_, _) async => AiToolResult.fail('non'),
      hasTool: (_) => false,
    );

final _refProbe = Provider<Ref>((ref) => ref);

Song _song(int id, String title, String artist) => Song(
      id: id,
      title: title,
      artist: artist,
      album: '',
      duration: 180000,
      filePath: '/musique/$id.mp3',
    );

void main() {
  group('registre', () {
    test('contient les 21 outils attendus', () {
      final registry = buildAiToolRegistry();
      expect(registry.length, _expectedTools.length);
      for (final name in _expectedTools) {
        expect(registry[name], isNotNull, reason: 'outil manquant : $name');
        expect(registry[name]!.name, name);
      }
    });

    test('les noms sont uniques et en snake_case', () {
      final registry = buildAiToolRegistry();
      final names = registry.names.toList();
      expect(names.toSet().length, names.length);
      for (final name in names) {
        expect(name, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
      }
    });

    test('chaque outil a une description et un schéma', () {
      final registry = buildAiToolRegistry();
      for (final name in registry.names) {
        final tool = registry[name]!;
        expect(tool.description.trim(), isNotEmpty);
        expect(tool.parametersSchema, isNotEmpty);
        expect(tool.parametersSchema['type'], 'object');
      }
    });

    test('describeForLlm mentionne chaque outil', () {
      final doc = buildAiToolRegistry().describeForLlm();
      for (final name in _expectedTools) {
        expect(doc, contains(name));
      }
      for (final name in _confirmingTools) {
        expect(doc, contains(name));
      }
    });

    test('les outils destructeurs exigent une confirmation', () {
      final registry = buildAiToolRegistry();
      for (final name in registry.names) {
        expect(
          registry[name]!.requiresConfirmation,
          _confirmingTools.contains(name),
          reason: name,
        );
      }
    });

    test('outil inconnu : null', () {
      expect(buildAiToolRegistry()['n_existe_pas'], isNull);
    });
  });

  group('arguments', () {
    test('reqString refuse null, vide, non-texte', () {
      expect(() => reqString({}, 'q'), throwsA(isA<AiToolArgError>()));
      expect(
        () => reqString({'q': '  '}, 'q'),
        throwsA(isA<AiToolArgError>()),
      );
      expect(
        () => reqString({'q': 3}, 'q'),
        throwsA(isA<AiToolArgError>()),
      );
      expect(reqString({'q': '  x '}, 'q'), 'x');
    });

    test('optString : null si absent ou vide', () {
      expect(optString({}, 'q'), isNull);
      expect(optString({'q': '  '}, 'q'), isNull);
      expect(optString({'q': 'x'}, 'q'), 'x');
      expect(
        () => optString({'q': 3}, 'q'),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('reqInt/optInt acceptent int et double entier', () {
      expect(reqInt({'n': 5}, 'n'), 5);
      expect(reqInt({'n': 5.0}, 'n'), 5);
      expect(optInt({}, 'n'), isNull);
      expect(() => reqInt({'n': '5'}, 'n'), throwsA(isA<AiToolArgError>()));
      expect(() => reqInt({'n': 5.5}, 'n'), throwsA(isA<AiToolArgError>()));
    });

    test('optBool : défaut faux', () {
      expect(optBool({}, 'b'), isFalse);
      expect(optBool({'b': true}, 'b'), isTrue);
      expect(
        () => optBool({'b': 'oui'}, 'b'),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('optMap : objet ou vide', () {
      expect(optMap({}, 'a'), isEmpty);
      expect(optMap({'a': {'x': 1}}, 'a'), {'x': 1});
      expect(
        () => optMap({'a': 'x'}, 'a'),
        throwsA(isA<AiToolArgError>()),
      );
    });
  });

  group('matchSongs', () {
    final songs = [
      _song(1, 'Café del Mar', 'Energy 52'),
      _song(2, 'Lucid Dreams', 'Juice WRLD'),
      _song(3, 'BANDITI', 'Juice WRLD'),
    ];

    test('trouve par titre, insensible à la casse', () {
      expect(matchSongs(songs, 'lucid').map((s) => s.id), [2]);
    });

    test('trouve par artiste, insensible aux accents', () {
      expect(matchSongs(songs, 'cafe').map((s) => s.id), [1]);
    });

    test('plusieurs résultats', () {
      expect(matchSongs(songs, 'juice').map((s) => s.id), [2, 3]);
    });

    test('requête vide : rien', () {
      expect(matchSongs(songs, '  '), isEmpty);
    });

    test('sans résultat : vide', () {
      expect(matchSongs(songs, 'xyz'), isEmpty);
    });
  });

  group('describeAction (sans exécution)', () {
    test('play sans query : reprise', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['play']!;
      expect(await tool.describeAction(ctx, {}), contains('Reprendre'));
      expect(
        await tool.describeAction(ctx, {'query': 'juice'}),
        contains('juice'),
      );
    });

    test('schedule_action refuse l’action inconnue', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['schedule_action']!;
      expect(
        tool.execute(ctx, {'in_minutes': 5, 'action': 'nope'}),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('schedule_action refuse de se planifier elle-même', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['schedule_action']!;
      expect(
        tool.execute(ctx, {'in_minutes': 5, 'action': 'schedule_action'}),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('sleep_timer exige minutes ou disabled', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['sleep_timer']!;
      // sleepTimerProvider a besoin du scope natif : on ne teste que la
      // validation des arguments, avant tout accès au notifier.
      expect(
        tool.execute(ctx, {}),
        throwsA(isA<AiToolArgError>()),
      );
      expect(
        tool.execute(ctx, {'minutes': 0}),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('set_appearance refuse les valeurs inconnues', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['set_appearance']!;
      expect(
        tool.execute(ctx, {'font_size': 'énorme'}),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('edit_tags exige au moins un champ', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['edit_tags']!;
      expect(tool.execute(ctx, {}), throwsA(isA<AiToolArgError>()));
    });
  });
}
