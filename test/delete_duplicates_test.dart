/// Tests C15 / C16 (scan DeepSeek, lot C hautes n°15-16) :
///
/// - C15 : deux entrées qui partagent le même `filePath` ne doivent jamais
///   faire supprimer le fichier gardé.
/// - C16 : un morceau sans titre ne doit pas être groupé comme doublon sur
///   la seule base de l'artiste.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/ai_tool_registry.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';

AiToolContext _ctx(Ref ref) => AiToolContext(
      ref: ref,
      runTool: (_, _) async => AiToolResult.fail('non'),
      hasTool: (_) => false,
      requiresConfirmation: (_) => false,
    );

final _refProbe = Provider<Ref>((ref) => ref);

Song _song(int id, String title, String artist, String file) => Song(
      id: id,
      title: title,
      artist: artist,
      album: '',
      duration: 200000,
      filePath: file,
    );

/// Scanner factice : aucun morceau n'a de paroles synchronisées, le gardé
/// est donc toujours le premier du groupe (après déduplication par chemin).
class _FakeScanner extends LyricsStatusScanner {
  @override
  Future<LyricsStatus> statusOf(String filePath) async =>
      LyricsStatus.none;
}

class _FakeSongList extends SongListNotifier {
  final List<Song> songs;
  _FakeSongList(this.songs);

  @override
  Future<List<Song>> build() async => songs;
}

void main() {
  // AudioPlayerService() touche aux MethodChannel (audio_session) dès sa
  // construction : le binding doit exister avant.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('delete_duplicates');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<File> makeFile(String name) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsString('fausse piste audio');
    return f;
  }

  ProviderContainer makeContainer(List<Song> songs) {
    final container = ProviderContainer(
      overrides: [
        songListProvider.overrideWith(() => _FakeSongList(songs)),
        lyricsStatusScannerProvider.overrideWithValue(_FakeScanner()),
        audioPlayerServiceProvider.overrideWithValue(AudioPlayerService()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('C16 — morceaux sans titre', () {
    test('deux morceaux sans titre du même artiste ne forment pas un groupe',
        () async {
      final container = makeContainer([
        _song(1, '', 'Juice WRLD', '/a/x.mp3'),
        _song(2, '', 'Juice WRLD', '/b/y.mp3'),
      ]);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['find_duplicates']!;
      final result = await tool.execute(ctx, {});
      expect(result.ok, isTrue);
      expect(result.message, contains('Aucun doublon'));
    });

    test('un morceau sans titre ne se groupe pas avec un morceau titré',
        () async {
      final container = makeContainer([
        _song(1, '', 'Juice WRLD', '/a/x.mp3'),
        _song(2, 'Lean Wit Me', 'Juice WRLD', '/b/y.mp3'),
      ]);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['find_duplicates']!;
      final result = await tool.execute(ctx, {});
      expect(result.ok, isTrue);
      expect(result.message, contains('Aucun doublon'));
    });

    test('même titre sans artiste : toujours un groupe (le titre suffit)',
        () async {
      final container = makeContainer([
        _song(1, 'Lean Wit Me', '', '/a/x.mp3'),
        _song(2, 'Lean Wit Me', '', '/b/y.mp3'),
      ]);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['find_duplicates']!;
      final result = await tool.execute(ctx, {});
      expect(result.ok, isTrue);
      expect(result.message, contains('2 fichiers en double'));
    });
  });

  group('C15 — même filePath partagé', () {
    test('le fichier gardé survit quand une autre entrée partage son chemin',
        () async {
      final kept = await makeFile('garde.mp3');
      final other = await makeFile('autre.mp3');
      final container = makeContainer([
        _song(1, 'Lean Wit Me', 'Juice WRLD', kept.path),
        _song(2, 'Lean Wit Me', 'Juice WRLD', kept.path),
        _song(3, 'Lean Wit Me', 'Juice WRLD', other.path),
      ]);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['delete_duplicates']!;
      final result = await tool.execute(ctx, {});
      expect(result.ok, isTrue);
      expect(result.message, contains('1 fichier en double supprimé'));
      // Le fichier gardé est intact, le vrai doublon est supprimé.
      expect(await kept.exists(), isTrue);
      expect(await other.exists(), isFalse);
    });

    test('un groupe qui ne désigne qu’un seul fichier est ignoré',
        () async {
      final only = await makeFile('unique.mp3');
      final container = makeContainer([
        _song(1, 'Lean Wit Me', 'Juice WRLD', only.path),
        _song(2, 'Lean Wit Me', 'Juice WRLD', only.path),
      ]);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['delete_duplicates']!;
      final result = await tool.execute(ctx, {});
      expect(result.ok, isTrue);
      expect(result.message, contains('0 fichier en double supprimé'));
      expect(result.message, contains('1 groupe ignoré'));
      expect(await only.exists(), isTrue);
    });

    test('describeAction refuse un groupe qui ne désigne qu’un seul fichier',
        () async {
      final only = await makeFile('unique.mp3');
      final container = makeContainer([
        _song(1, 'Lean Wit Me', 'Juice WRLD', only.path),
        _song(2, 'Lean Wit Me', 'Juice WRLD', only.path),
      ]);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['delete_duplicates']!;
      expect(
        tool.describeAction(ctx, {}),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('contrôle : des chemins distincts suppriment toujours le doublon',
        () async {
      final kept = await makeFile('garde.mp3');
      final dupe = await makeFile('doublon.mp3');
      final container = makeContainer([
        _song(1, 'Lean Wit Me', 'Juice WRLD', kept.path),
        _song(2, 'Lean Wit Me', 'Juice WRLD', dupe.path),
      ]);
      final ctx = _ctx(container.read(_refProbe));
      final tool = buildAiToolRegistry()['delete_duplicates']!;
      final result = await tool.execute(ctx, {});
      expect(result.ok, isTrue);
      expect(result.message, contains('1 fichier en double supprimé'));
      expect(await kept.exists(), isTrue);
      expect(await dupe.exists(), isFalse);
    });
  });
}
