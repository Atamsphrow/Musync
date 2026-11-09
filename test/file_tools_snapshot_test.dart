/// Cible figée entre confirmation et exécution (critiques A1/A2 du scan
/// DeepSeek, lot A).
///
/// Le bug : `describeAction` et `execute` re-résolvaient chacun la cible
/// (`currentSong` ou bibliothèque), donc une action destructive pouvait porter
/// sur un autre fichier que celui confirmé. Le correctif fige les cibles au
/// moment de `describeAction` et les transmet à `execute` via `args`.
///
/// Chaque test suit le même scénario : décrire avec le morceau A en cours (ou
/// la bibliothèque [A, B]), changer l'état (morceau en cours = B, ou
/// bibliothèque = [B, C]), exécuter avec LA MÊME Map `args`, puis vérifier
/// que c'est le fichier de A — pas celui de B — qui a été touché. Les fichiers
/// sont réels (MP3 nus dans un dossier temporaire), les effets sont donc
/// observables sur disque, pas sur des mocks.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/tools/file_tools.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/lyrics/data/ai_filename_resolver.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';

/// MP3 nu : un en-tête de trame MP3 suivi de données quelconques. Suffit à
/// `Id3Writer` pour écrire des tags (voir `audio_container_test.dart`).
Uint8List _bareMp3() => Uint8List.fromList([
      0xFF, 0xFB, 0x90, 0x00,
      ...List<int>.generate(2048, (i) => (i * 11) % 256),
    ]);

/// Faux lecteur : le morceau en cours est une variable, pas just_audio
/// (dont le constructeur exige un moteur natif).
class _FakePlayer extends AudioPlayerService {
  Song? current;
  List<Song> queueList = [];

  @override
  Song? get currentSong => current;

  @override
  List<Song> get queue => queueList;

  @override
  Future<void> next() async {
    if (queueList.length > 1) current = queueList[1];
  }

  @override
  Future<void> stop() async {
    current = null;
  }

  @override
  Future<void> removeFromQueue(int index) async {
    if (index >= 0 && index < queueList.length) {
      queueList = List.of(queueList)..removeAt(index);
    }
  }

  @override
  void updateCurrentSongMetadata({
    required String title,
    required String artist,
    required String album,
  }) {}

  /// Chemins signalés par `updateSongPath` (E19) : le lecteur suit les
  /// renommages/déplacements au lieu de garder l'ancien chemin.
  final pathUpdates = <(String, String)>[];

  @override
  void updateSongPath(String oldPath, String newPath) {
    pathUpdates.add((oldPath, newPath));
  }

  @override
  Future<void> forgetArtwork(Song song) async {}
}

/// Bibliothèque modifiable entre `describeAction` et `execute`.
class _MutableSongList extends SongListNotifier {
  List<Song> songs;

  /// Nombre de constructions : chaque invalidation de `songListProvider`
  /// en déclenche une (E25).
  var builds = 0;

  _MutableSongList(this.songs);

  @override
  Future<List<Song>> build() async {
    builds++;
    return songs;
  }
}

class _FakeSettingsStore extends AiSettingsStore {
  final AiSettings settings;
  _FakeSettingsStore(this.settings);

  @override
  Future<AiSettings> load() async => settings;
}

/// Lecteur de noms de fichiers scripté : rend toujours la même correction.
class _ScriptedReader extends AiFilenameReader {
  final FilenameGuess guess;
  int asked = 0;

  _ScriptedReader(this.guess);

  @override
  Future<FilenameGuess> read({
    required AiProviderConfig provider,
    required String instruction,
    required String fileName,
  }) async {
    asked++;
    return guess;
  }
}

AiProviderConfig _provider() => const AiProviderConfig(
      id: 'test',
      name: 'Modèle test',
      kind: AiProviderKind.gemini,
      baseUrl: 'https://exemple.test/v1',
      model: 'modele-test',
      apiKey: 'k',
    );

AiToolContext _ctx(Ref ref) => AiToolContext(
      ref: ref,
      runTool: (_, _) async => AiToolResult.fail('non'),
      hasTool: (_) => false,
      requiresConfirmation: (_) => false,
    );

final _refProbe = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakePlayer player;
  late _MutableSongList library;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_snapshot_');
    // `getTemporaryDirectory` passe par un canal de plateforme, absent en
    // test : on le sert avec le dossier temporaire du test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getTemporaryDirectory' ||
            call.method == 'getApplicationSupportDirectory') {
          return tempDir.path;
        }
        return null;
      },
    );
    player = _FakePlayer();
    library = _MutableSongList(const []);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> makeTrack(String name) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(_bareMp3());
    return file.path;
  }

  Song song(int id, String title, String artist, String path) => Song(
        id: id,
        title: title,
        artist: artist,
        album: '',
        duration: 180000,
        filePath: path,
      );

  ProviderContainer container({List<Override> extra = const []}) {
    final container = ProviderContainer(
      overrides: [
        songListProvider.overrideWith(() => library),
        audioPlayerServiceProvider.overrideWithValue(player),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('snapshot de cible : currentSong change entre describe et execute',
      () {
    test('delete_file supprime le morceau confirmé, pas le nouveau courant',
        () async {
      final pathA = await makeTrack('a.mp3');
      final pathB = await makeTrack('b.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      final songB = song(2, 'Titre B', 'Artiste B', pathB);
      library.songs = [songA, songB];
      player.current = songA;
      player.queueList = [songA, songB];
      final ctx = _ctx(container().read(_refProbe));

      const tool = DeleteFileTool();
      final args = <String, Object?>{};
      final preview = await tool.describeAction(ctx, args);
      expect(preview, contains('Titre A'));

      // L'utilisateur change de morceau pendant que le dialogue est ouvert.
      player.current = songB;

      final result = await tool.execute(ctx, args);
      expect(result.ok, isTrue);
      expect(await File(pathA).exists(), isFalse, reason: 'A supprimé');
      expect(await File(pathB).exists(), isTrue, reason: 'B intact');
    });

    test('edit_tags écrit dans le morceau confirmé, pas le nouveau courant',
        () async {
      final pathA = await makeTrack('a.mp3');
      final pathB = await makeTrack('b.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      final songB = song(2, 'Titre B', 'Artiste B', pathB);
      library.songs = [songA, songB];
      player.current = songA;
      final ctx = _ctx(container().read(_refProbe));

      const tool = EditTagsTool();
      final args = <String, Object?>{'title': 'Nouveau Titre'};
      final preview = await tool.describeAction(ctx, args);
      expect(preview, contains('Titre A'));

      player.current = songB;

      final result = await tool.execute(ctx, args);
      expect(result.ok, isTrue, reason: result.message);
      expect((await Id3Reader.readMetadata(pathA)).title, 'Nouveau Titre');
      expect((await Id3Reader.readMetadata(pathB)).title, isNull);
    });

    test('change_cover touche le morceau confirmé, pas le nouveau courant',
        () async {
      final pathA = await makeTrack('a.mp3');
      final pathB = await makeTrack('b.mp3');
      final image = File('${tempDir.path}${Platform.pathSeparator}pochette.png');
      await image.writeAsBytes([
        0x89, 0x50, 0x4E, 0x47, // Signature PNG.
        ...List<int>.generate(64, (i) => i),
      ]);
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      final songB = song(2, 'Titre B', 'Artiste B', pathB);
      library.songs = [songA, songB];
      player.current = songA;
      final ctx = _ctx(container().read(_refProbe));

      const tool = ChangeCoverTool();
      final args = <String, Object?>{'image': image.path};
      final preview = await tool.describeAction(ctx, args);
      expect(preview, contains('Titre A'));

      player.current = songB;

      final result = await tool.execute(ctx, args);
      expect(result.ok, isTrue, reason: result.message);
      // La pochette est écrite telle quelle dans le tag : la signature PNG
      // complète doit se retrouver dans A, pas dans B.
      bool hasPngSignature(List<int> bytes) {
        const sig = [0x89, 0x50, 0x4E, 0x47];
        for (var i = 0; i + sig.length <= bytes.length; i++) {
          var found = true;
          for (var j = 0; j < sig.length; j++) {
            if (bytes[i + j] != sig[j]) {
              found = false;
              break;
            }
          }
          if (found) return true;
        }
        return false;
      }

      final bytesA = await File(pathA).readAsBytes();
      final bytesB = await File(pathB).readAsBytes();
      expect(hasPngSignature(bytesA), isTrue, reason: 'pochette dans A');
      expect(hasPngSignature(bytesB), isFalse, reason: 'rien dans B');
    });

    test('move_songs déplace le morceau confirmé, pas le nouveau courant',
        () async {
      final pathA = await makeTrack('a.mp3');
      final pathB = await makeTrack('b.mp3');
      final dest = Directory('${tempDir.path}${Platform.pathSeparator}dest');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      final songB = song(2, 'Titre B', 'Artiste B', pathB);
      library.songs = [songA, songB];
      player.current = songA;
      final ctx = _ctx(container().read(_refProbe));

      const tool = MoveSongsTool();
      final args = <String, Object?>{'folder': dest.path};
      final preview = await tool.describeAction(ctx, args);
      expect(preview, contains('Titre A'));

      player.current = songB;

      final result = await tool.execute(ctx, args);
      expect(result.ok, isTrue, reason: result.message);
      expect(
        await File('${dest.path}${Platform.pathSeparator}a.mp3').exists(),
        isTrue,
        reason: 'A déplacé',
      );
      expect(await File(pathA).exists(), isFalse);
      expect(await File(pathB).exists(), isTrue, reason: 'B intact');
    });

    test(
        'fix_tags_from_filename corrige le morceau confirmé, sans rappeler '
        'l’IA', () async {
      final pathA = await makeTrack('Stromae - Papaoutai.mp3');
      final pathB = await makeTrack('Autre - Chanson.mp3');
      final songA = song(1, 'Papaoutai', 'Stromae', pathA);
      final songB = song(2, 'Chanson', 'Autre', pathB);
      library.songs = [songA, songB];
      player.current = songA;
      final reader = _ScriptedReader(
        (artist: 'Stromae', title: 'Papaoutai'),
      );
      final settings = AiSettings(providers: [_provider()]);
      final ctx = _ctx(
        container(
          extra: [
            aiSettingsStoreProvider.overrideWithValue(
              _FakeSettingsStore(settings),
            ),
            aiFilenameResolverProvider.overrideWithValue(
              AiFilenameResolver(reader),
            ),
          ],
        ).read(_refProbe),
      );

      const tool = FixTagsFromFilenameTool();
      final args = <String, Object?>{};
      final preview = await tool.describeAction(ctx, args);
      expect(preview, contains('Papaoutai'));
      expect(reader.asked, 1);

      player.current = songB;

      final result = await tool.execute(ctx, args);
      expect(result.ok, isTrue, reason: result.message);
      // La correction montrée est celle qui est écrite, et l'IA n'a été
      // appelée qu'une fois (à la description), pas à l'exécution.
      expect(reader.asked, 1);
      expect((await Id3Reader.readMetadata(pathA)).title, 'Papaoutai');
      expect((await Id3Reader.readMetadata(pathA)).artist, 'Stromae');
      expect((await Id3Reader.readMetadata(pathB)).title, isNull);
    });
  });

  group('snapshot de cible : bibliothèque change entre describe et execute',
      () {
    test('batch_rename_files renomme la liste confirmée, pas la nouvelle',
        () async {
      final pathA = await makeTrack('a.mp3');
      final pathB = await makeTrack('b.mp3');
      final pathC = await makeTrack('c.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      final songB = song(2, 'Titre B', 'Artiste B', pathB);
      final songC = song(3, 'Titre C', 'Artiste C', pathC);
      library.songs = [songA, songB];
      final testContainer = container();
      final ctx = _ctx(testContainer.read(_refProbe));

      const tool = BatchRenameFilesTool();
      final args = <String, Object?>{};
      final preview = await tool.describeAction(ctx, args);
      expect(preview, contains('2 fichiers'));

      // La bibliothèque change avant la confirmation : C arrive, A part.
      library.songs = [songB, songC];
      testContainer.invalidate(songListProvider);

      final result = await tool.execute(ctx, args);
      expect(result.ok, isTrue, reason: result.message);
      expect(
        await File(
          '${tempDir.path}${Platform.pathSeparator}Artiste A - Titre A.mp3',
        ).exists(),
        isTrue,
        reason: 'A renommé (confirmé)',
      );
      expect(
        await File(
          '${tempDir.path}${Platform.pathSeparator}Artiste B - Titre B.mp3',
        ).exists(),
        isTrue,
        reason: 'B renommé (confirmé)',
      );
      expect(await File(pathC).exists(), isTrue, reason: 'C intact');
      expect(await File(pathA).exists(), isFalse);
      expect(await File(pathB).exists(), isFalse);
    });

    test('move_songs all=true déplace la liste confirmée, pas la nouvelle',
        () async {
      final pathA = await makeTrack('a.mp3');
      final pathB = await makeTrack('b.mp3');
      final pathC = await makeTrack('c.mp3');
      final dest = Directory('${tempDir.path}${Platform.pathSeparator}dest');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      final songB = song(2, 'Titre B', 'Artiste B', pathB);
      final songC = song(3, 'Titre C', 'Artiste C', pathC);
      library.songs = [songA, songB];
      final testContainer = container();
      final ctx = _ctx(testContainer.read(_refProbe));

      const tool = MoveSongsTool();
      final args = <String, Object?>{'folder': dest.path, 'all': true};
      final preview = await tool.describeAction(ctx, args);
      expect(preview, contains('2 morceaux'));

      library.songs = [songB, songC];
      testContainer.invalidate(songListProvider);

      final result = await tool.execute(ctx, args);
      expect(result.ok, isTrue, reason: result.message);
      expect(
        await File('${dest.path}${Platform.pathSeparator}a.mp3').exists(),
        isTrue,
        reason: 'A déplacé (confirmé)',
      );
      expect(
        await File('${dest.path}${Platform.pathSeparator}b.mp3').exists(),
        isTrue,
        reason: 'B déplacé (confirmé)',
      );
      expect(await File(pathC).exists(), isTrue, reason: 'C intact');
    });
  });

  group('sans describe préalable : exécution directe inchangée', () {
    test('delete_file avec query agit sur le morceau requêté', () async {
      final pathA = await makeTrack('a.mp3');
      final pathB = await makeTrack('b.mp3');
      final songA = song(1, 'Lean Wit Me', 'Juice WRLD', pathA);
      final songB = song(2, 'Lucid Dreams', 'Juice WRLD', pathB);
      library.songs = [songA, songB];
      player.current = songB;
      player.queueList = [songA, songB];
      final ctx = _ctx(container().read(_refProbe));

      final result = await const DeleteFileTool().execute(ctx, {
        'query': 'lean wit me',
      });
      expect(result.ok, isTrue);
      expect(await File(pathA).exists(), isFalse);
      expect(await File(pathB).exists(), isTrue);
    });

    test('args constante : le snapshot survit via le repli', () async {
      // Le contrôleur passe `const {}` quand le modèle omet « args » : la
      // Map refuse l'écriture, le snapshot passe par le repli interne.
      final pathA = await makeTrack('a.mp3');
      final pathB = await makeTrack('b.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      final songB = song(2, 'Titre B', 'Artiste B', pathB);
      library.songs = [songA, songB];
      player.current = songA;
      player.queueList = [songA, songB];
      final ctx = _ctx(container().read(_refProbe));

      const tool = DeleteFileTool();
      final preview = await tool.describeAction(ctx, const {});
      expect(preview, contains('Titre A'));

      player.current = songB;

      // `execute` reçoit une Map fraîche, sans snapshot : seul le repli
      // (consommé d'un coup) peut encore désigner A.
      final result = await tool.execute(ctx, {});
      expect(result.ok, isTrue);
      expect(await File(pathA).exists(), isFalse, reason: 'A supprimé');
      expect(await File(pathB).exists(), isTrue, reason: 'B intact');
    });
  });

  group('revalidation B7/E19/E21/E22/E23/E24/E25', () {
    test('batch_rename_files signale le nouveau chemin au lecteur (E19)',
        () async {
      final pathA = await makeTrack('a.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      library.songs = [songA];
      player.current = songA;
      player.queueList = [songA];
      final ctx = _ctx(container().read(_refProbe));

      const tool = BatchRenameFilesTool();
      final result = await tool.execute(ctx, {'query': 'Titre A'});
      expect(result.ok, isTrue, reason: result.message);
      final renamed =
          '${tempDir.path}${Platform.pathSeparator}Artiste A - Titre A.mp3';
      expect(await File(renamed).exists(), isTrue);
      expect(player.pathUpdates, [(pathA, renamed)]);
    });

    test('move_songs signale le nouveau chemin au lecteur (E19)', () async {
      final pathA = await makeTrack('a.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      library.songs = [songA];
      player.current = songA;
      player.queueList = [songA];
      final dest = Directory('${tempDir.path}${Platform.pathSeparator}dest');
      final ctx = _ctx(container().read(_refProbe));

      const tool = MoveSongsTool();
      final result = await tool.execute(
        ctx,
        {'folder': dest.path, 'query': 'Titre A'},
      );
      expect(result.ok, isTrue, reason: result.message);
      final moved = '${dest.path}${Platform.pathSeparator}a.mp3';
      expect(await File(moved).exists(), isTrue);
      expect(player.pathUpdates, [(pathA, moved)]);
    });

    test('change_cover refuse un RIFF qui n’est pas WebP (E21)', () async {
      final pathA = await makeTrack('a.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      library.songs = [songA];
      player.current = songA;
      // WAV : RIFF + taille + « WAVE » — pas une image.
      final wav = File('${tempDir.path}${Platform.pathSeparator}son.wav');
      await wav.writeAsBytes(Uint8List.fromList([
        ...'RIFF'.codeUnits,
        0, 0, 0, 0,
        ...'WAVE'.codeUnits,
        ...List<int>.generate(64, (i) => i),
      ]));
      final ctx = _ctx(container().read(_refProbe));

      const tool = ChangeCoverTool();
      final result = await tool.execute(ctx, {'image': wav.path});
      expect(result.ok, isFalse);
      expect(result.message, contains('pas une image reconnue'));
    });

    test('change_cover accepte un vrai WebP (E21)', () async {
      final pathA = await makeTrack('a.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      library.songs = [songA];
      player.current = songA;
      final webp = File('${tempDir.path}${Platform.pathSeparator}pochette.webp');
      await webp.writeAsBytes(Uint8List.fromList([
        ...'RIFF'.codeUnits,
        0, 0, 0, 0,
        ...'WEBP'.codeUnits,
        ...'VP8 '.codeUnits,
        ...List<int>.generate(32, (i) => i),
      ]));
      final ctx = _ctx(container().read(_refProbe));

      const tool = ChangeCoverTool();
      final result = await tool.execute(ctx, {'image': webp.path});
      expect(result.ok, isTrue, reason: result.message);
    });

    test('change_cover refuse une image de plus de 20 Mo (E22)', () async {
      final pathA = await makeTrack('a.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      library.songs = [songA];
      player.current = songA;
      final big = File('${tempDir.path}${Platform.pathSeparator}grosse.jpg');
      await big.writeAsBytes(Uint8List(20 * 1024 * 1024 + 1));
      final ctx = _ctx(container().read(_refProbe));

      const tool = ChangeCoverTool();
      final result = await tool.execute(ctx, {'image': big.path});
      expect(result.ok, isFalse);
      expect(result.message, contains('trop volumineuse'));
    });

    test('edit_tags invalide la liste après écriture (E25)', () async {
      final pathA = await makeTrack('a.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      library.songs = [songA];
      player.current = songA;
      final testContainer = container();
      final ctx = _ctx(testContainer.read(_refProbe));

      // Première lecture : construit la liste une fois.
      expect(await testContainer.read(songListProvider.future), [songA]);
      expect(library.builds, 1);

      const tool = EditTagsTool();
      final result = await tool.execute(ctx, {'title': 'Nouveau Titre'});
      expect(result.ok, isTrue, reason: result.message);

      // La liste est reconstruite à la lecture suivante : l'invalidation a
      // eu lieu, le titre affiché ne reste pas l'ancien.
      await testContainer.read(songListProvider.future);
      expect(library.builds, 2);
    });

    test('aucun .tmp orphelin après succès ou échec d’écriture (E23/E24)',
        () async {
      final pathA = await makeTrack('a.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      library.songs = [songA];
      player.current = songA;
      final ctx = _ctx(container().read(_refProbe));

      const tool = EditTagsTool();
      // Succès.
      var result = await tool.execute(ctx, {'title': 'Nouveau Titre'});
      expect(result.ok, isTrue, reason: result.message);
      // Échec : fichier disparu entre la confirmation et l'écriture.
      await File(pathA).delete();
      result = await tool.execute(ctx, {'title': 'Autre Titre'});
      expect(result.ok, isFalse);

      final leftovers = await tempDir
          .list()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test(
        'deux écritures concurrentes sur le même morceau ne se marchent '
        'pas dessus (E23)', () async {
      final pathA = await makeTrack('a.mp3');
      final songA = song(1, 'Titre A', 'Artiste A', pathA);
      library.songs = [songA];
      player.current = songA;
      final ctx = _ctx(container().read(_refProbe));

      const tool = EditTagsTool();
      final results = await Future.wait([
        tool.execute(ctx, {'title': 'Titre Un'}),
        tool.execute(ctx, {'title': 'Titre Deux'}),
      ]);
      for (final result in results) {
        expect(result.ok, isTrue, reason: result.message);
      }
      final leftovers = await tempDir
          .list()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });
}
