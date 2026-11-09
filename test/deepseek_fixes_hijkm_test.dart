/// Tests des correctifs des findings CONFIRMÉS lots H/I/J/K/M du scan
/// DeepSeek Musync (vague 3 : outils / id3 / assistant / scanner).
///
/// Chaque groupe est nommé par son finding, pour retrouver le correctif
/// depuis le rapport de vérification (`verify/batch-*.md`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:on_audio_query/on_audio_query.dart';
import 'package:musync/core/audio/mp3_gapless.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/m4a_writer.dart';
import 'package:musync/core/id3/tag_metadata.dart';
import 'package:musync/core/router/app_router.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/media_store.dart';
import 'package:musync/features/lyrics/data/ai_filename_reader.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/assistant_bridge.dart';
import 'package:musync/features/ai_assistant/data/tools/file_tools.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';
import 'package:musync/features/library/data/tag_mtime_store.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/settings/data/ai_provider_config.dart';

// ── Harnais partagé (faux lecteur + bibliothèque mutable) ───────────────

Uint8List _bareMp3() => Uint8List.fromList([
      0xFF, 0xFB, 0x90, 0x00,
      ...List<int>.generate(2048, (i) => (i * 11) % 256),
    ]);

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

  @override
  Future<void> forgetArtwork(Song song) async {}
}

class _MutableSongList extends SongListNotifier {
  List<Song> songs;
  _MutableSongList(this.songs);

  @override
  Future<List<Song>> build() async => songs;
}

AiToolContext _ctx(Ref ref) => AiToolContext(
      ref: ref,
      runTool: (_, _) async => AiToolResult.fail('non'),
      hasTool: (_) => false,
      requiresConfirmation: (_) => false,
    );

final _refProbe = Provider<Ref>((ref) => ref);

Song _song(int id, String title, String artist, String path) => Song(
      id: id,
      title: title,
      artist: artist,
      album: '',
      duration: 180000,
      filePath: path,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakePlayer player;
  late _MutableSongList library;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_wave3_');
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.atamsphrow.musync/media_store'),
      null,
    );
    DebugLog.instance.clear();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> makeTrack(String name, [List<int>? bytes]) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes ?? _bareMp3());
    return file.path;
  }

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        songListProvider.overrideWith(() => library),
        audioPlayerServiceProvider.overrideWithValue(player),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('I22 — pattern de renommage validé', () {
    test('un motif inconnu est rejeté, pas replié silencieusement', () async {
      final path = await makeTrack('a.mp3');
      library.songs = [_song(1, 'Titre', 'Artiste', path)];
      final ctx = _ctx(container().read(_refProbe));
      const tool = BatchRenameFilesTool();
      await expectLater(
        () => tool.describeAction(ctx, {'pattern': 'artiste-titre'}),
        throwsA(isA<AiToolArgError>()),
      );
      await expectLater(
        () => tool.execute(ctx, {'pattern': 'nimporte'}),
        throwsA(isA<AiToolArgError>()),
      );
    });

    test('contrôle : les deux motifs connus passent', () async {
      final path = await makeTrack('a.mp3');
      library.songs = [_song(1, 'Titre', 'Artiste', path)];
      final ctx = _ctx(container().read(_refProbe));
      const tool = BatchRenameFilesTool();
      final preview = await tool.describeAction(
        ctx,
        {'pattern': 'title-artist'},
      );
      expect(preview, contains('Titre - Artiste'));
    });
  });

  group('I23 — aperçu de confirmation assaini', () {
    test('un \\n dans un titre ne crée pas de fausse ligne', () async {
      final path = await makeTrack('a.mp3');
      final evil = _song(1, 'Titre\nFAUSSE LIGNE', 'Artiste', path);
      player.current = evil;
      final ctx = _ctx(container().read(_refProbe));
      const tool = EditTagsTool();
      final preview = await tool.describeAction(ctx, {
        'title': 'Nouveau\nTitre',
      });
      final lines = preview.split('\n').map((l) => l.trim()).toList();
      expect(lines, isNot(contains('FAUSSE LIGNE')));
      expect(preview, contains('Nouveau Titre'));
    });
  });

  group('I24 — dossier créé après résolution des cibles', () {
    test('aucun morceau visé : le dossier n’apparaît pas', () async {
      final ctx = _ctx(container().read(_refProbe));
      const tool = MoveSongsTool();
      final dest =
          '${tempDir.path}${Platform.pathSeparator}nouveau_dossier';
      final result = await tool.execute(ctx, {'folder': dest});
      expect(result.ok, isFalse);
      expect(await Directory(dest).exists(), isFalse);
    });
  });

  group('I25 — _safeFileName : troncature et NUL', () {
    test('un titre de 300 caractères est tronqué à 200 octets', () async {
      final path = await makeTrack('x.mp3');
      library.songs = [_song(1, 'a' * 300, '', path)];
      final ctx = _ctx(container().read(_refProbe));
      const tool = BatchRenameFilesTool();
      final result = await tool.execute(ctx, {});
      expect(result.ok, isTrue, reason: result.message);
      final renamed = await tempDir.list().map((e) => e.path).toList();
      expect(renamed, hasLength(1));
      final base = renamed.single.split(Platform.pathSeparator).last;
      expect(base, '${'a' * 200}.mp3');
    });

    test('un NUL dans le titre devient un underscore', () async {
      final path = await makeTrack('x.mp3');
      library.songs = [_song(1, 'ab\x00cd', '', path)];
      final ctx = _ctx(container().read(_refProbe));
      const tool = BatchRenameFilesTool();
      final preview = await tool.describeAction(ctx, {});
      expect(preview, contains('ab_cd.mp3'));
    });
  });

  group('I27 — describe() sans sampleRate', () {
    test('sampleRate 0 + delay : pas de crash, durée inconnue', () {
      const info = Mp3GaplessInfo(
        sampleRate: 0,
        samplesPerFrame: 1152,
        hasXingHeader: true,
        encoderDelay: 576,
        encoderPadding: 0,
      );
      expect(info.describe(), contains('durée inconnue'));
    });
  });

  group('H95 — durée lue depuis le fichier (iOS)', () {
    test('MP3 Xing : durée exacte depuis le nombre de trames', () async {
      final file = File('${tempDir.path}/xing.mp3');
      await file.writeAsBytes(_xingFrame(frameCount: 9000));
      final duration = await MusicScanner.probeFileDuration(file.path);
      // 9000 trames × 1152 éch. à 44 100 Hz.
      expect(duration?.inMilliseconds, 235102);
    });

    test('FLAC : STREAMINFO (échantillons / fréquence)', () async {
      final file = File('${tempDir.path}/a.flac');
      await file.writeAsBytes(_flacHead(sampleRate: 44100, totalSamples: 44100 * 180));
      expect(
        (await MusicScanner.probeFileDuration(file.path))?.inSeconds,
        180,
      );
    });

    test('WAV : taille data / byteRate', () async {
      final file = File('${tempDir.path}/a.wav');
      await file.writeAsBytes(_wavHead(byteRate: 176400, dataSize: 176400 * 90));
      expect(
        (await MusicScanner.probeFileDuration(file.path))?.inSeconds,
        90,
      );
    });

    test('M4A : mvhd (timescale / durée)', () {
      final bytes = _m4aWithMvhd(timescale: 1000, duration: 183000);
      expect(M4aWriter.durationFromBytes(bytes)?.inSeconds, 183);
    });

    test('fichier inconnu : null, pas d’exception', () async {
      final file = File('${tempDir.path}/a.ogg');
      await file.writeAsBytes([1, 2, 3, 4]);
      expect(await MusicScanner.probeFileDuration(file.path), isNull);
    });
  });

  group('H97 + M122 — scan et refresh', () {
    test('durée null : le morceau est gardé, pas rejeté « trop court »',
        () async {
      final scanner = MusicScanner(
        audioQuery: _FakeAudioQuery([
          _fakeSongModel(1, '/Musique/sans_duree.mp3', duration: null),
          _fakeSongModel(2, '/Musique/court.mp3', duration: 5000),
          _fakeSongModel(3, '/Musique/normal.mp3', duration: 180000),
        ]),
      );
      final kept = await scanner.scanAllSongs();
      expect(
        kept.map((s) => s.filePath),
        ['/Musique/sans_duree.mp3', '/Musique/normal.mp3'],
      );
      expect(
        scanner.lastIgnored.map((i) => i.path),
        ['/Musique/court.mp3'],
      );
    });

    test('titre « <unknown> » : le nom de fichier gagne, comme artiste/album',
        () async {
      final path = await makeTrack(
        'piste.mp3',
        _id3TagBytes(
          major: 3,
          frames: [
            _Id3Frame('TIT2', [0, ...'<unknown>'.codeUnits]),
            _Id3Frame('TPE1', [0, ...'Vrai Artiste'.codeUnits]),
          ],
        ),
      );
      final scanner = MusicScanner(
        mtimeStore: TagMtimeStore(root: tempDir),
      );
      final song = _song(1, 'Ancien Titre', 'Ancien Artiste', path);
      final updated = await scanner.refreshMetadataFromFiles([song]);
      expect(updated.single.title, 'Ancien Titre');
      expect(updated.single.artist, 'Vrai Artiste');
    });

    test('refresh : l’ordre d’entrée est préservé (lots parallèles)',
        () async {
      final paths = <String>[];
      for (var i = 0; i < 12; i++) {
        paths.add(await makeTrack('p$i.mp3'));
      }
      final scanner = MusicScanner(
        mtimeStore: TagMtimeStore(root: tempDir),
      );
      final songs = [
        for (var i = 0; i < paths.length; i++)
          _song(i, 'Titre $i', 'Artiste', paths[i]),
      ];
      final updated = await scanner.refreshMetadataFromFiles(songs);
      expect(
        updated.map((s) => s.filePath).toList(),
        paths,
      );
    });
  });

  group('I28/I29 — lecture ID3 : opaque d’abord, tronqué propre', () {
    test('frame compressée : corps non lu, titre ignoré', () async {
      final path = await makeTrack(
        'opaque.mp3',
        _id3TagBytes(
          major: 3,
          frames: [
            // v2.3 : flagsLo 0x80 = compressée.
            _Id3Frame('TIT2', [0, ...'X'.codeUnits], flagsLo: 0x80),
            _Id3Frame('TPE1', [0, ...'Artiste'.codeUnits]),
          ],
        ),
      );
      final meta = await Id3Reader.readMetadata(path);
      expect(meta.title, isNull);
      expect(meta.artist, 'Artiste');
    });

    test('corps de frame tronqué : arrêt propre, pas de texte partiel',
        () async {
      final path = await makeTrack(
        'tronque.mp3',
        _id3TruncatedTag(),
      );
      final meta = await Id3Reader.readMetadata(path);
      expect(meta.title, isNull);
      expect(meta.artist, isNull);
      expect(meta.album, isNull);
    });

    test('tag déclaré plus grand que le fichier : « pas de paroles »',
        () async {
      final path = await makeTrack('tronque2.mp3', _id3OversizedTag());
      final pair = await Id3Reader.readLyrics(path);
      expect(pair.synced, isNull);
      expect(pair.unsynced, isNull);
    });
  });

  group('J32 — écriture ID3', () {
    test('contrôle : numéro + total écrivent « 7/5 »', () async {
      final path = await makeTrack('trck2.mp3');
      await Id3Writer.writeMetadata(path, _metadata(trackNumber: 7, trackTotal: 5));
      final read = await Id3Reader.readFullMetadata(path);
      expect(read.trackNumber, 7);
      expect(read.trackTotal, 5);
    });

    test('Id3WriteException.toString inclut la cause', () {
      const e = Id3WriteException('oups', 'cause-x');
      expect(e.toString(), contains('oups'));
      expect(e.toString(), contains('cause-x'));
      expect(const Id3WriteException('oups').toString(), 'Id3WriteException: oups');
    });
  });

  group('J35 — décalage stco : seuls les chunks après moov bougent', () {
    test('mdat avant moov : son chunk ne bouge pas, celui d’après si',
        () async {
      final before = _mdatFirstM4a();
      final file = File('${tempDir.path}/multi_mdat.m4a');
      await file.writeAsBytes(before.bytes);
      await M4aWriter.writeLrc(file.path, '[00:01.00]ligne');
      final after = await file.readAsBytes();
      final entriesBefore = _stcoEntries(before.bytes);
      final entriesAfter = _stcoEntries(after);
      expect(entriesAfter[0], entriesBefore[0],
          reason: 'chunk dans le mdat avant moov : immobile');
      final delta = _moovSize(after) - _moovSize(before.bytes);
      expect(delta, greaterThan(0));
      expect(entriesAfter[1], entriesBefore[1] + delta,
          reason: 'chunk après moov : décalé de la croissance de moov');
    });
  });

  group('J37 — ©lyr : type UTF-16 lu, UTF-8 mal formé toléré', () {
    test('©lyr UTF-16 : décodé, pas du mojibake', () async {
      final file = File('${tempDir.path}/utf16.m4a');
      await file.writeAsBytes(_m4aWithLyrUtf16('Hello UTF-16'));
      expect(await M4aWriter.readLrc(file.path), 'Hello UTF-16');
    });

    test('©lyr UTF-8 mal formé : toléré, pas d’exception', () async {
      final file = File('${tempDir.path}/malformed.m4a');
      await file.writeAsBytes(
        _m4aWithLyrBytes([0xFF, 0xFE, 0x61], type: 1),
      );
      final text = await M4aWriter.readLrc(file.path);
      expect(text, isNotNull);
      expect(text, contains('a'));
    });
  });

  group('J46/J47 — journal : redaction et borne once()', () {
    test('report() : le chemin devient le nom du fichier', () {
      DebugLog.instance.info(
        'MediaStore',
        'Réindexation refusée pour /storage/emulated/0/Music/titre.mp3',
      );
      final report = DebugLog.instance.report();
      expect(report, contains('titre.mp3'));
      expect(report, isNot(contains('/storage/emulated/0')));
    });

    test('once() : la plus vieille clé est oubliée passé le plafond',
        () {
      for (var i = 0; i < 130; i++) {
        DebugLog.instance.once('k$i', LogLevel.info, 'S', 'msg $i');
      }
      // k0 et k1 ont été évincées (plafond 128) : k0 se logue à nouveau.
      DebugLog.instance.once('k0', LogLevel.info, 'S', 'msg 0');
      final count = DebugLog.instance.entries
          .where((e) => e.message == 'msg 0')
          .length;
      expect(count, 2);
      // k129, elle, est toujours dedans : pas de doublon.
      DebugLog.instance.once('k129', LogLevel.info, 'S', 'msg 129');
      expect(
        DebugLog.instance.entries.where((e) => e.message == 'msg 129').length,
        1,
      );
    });
  });

  group('J48 — sdkInt() borné comme les autres appels', () {
    test('canal muet : null après ~5 s, pas d’attente infinie', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.atamsphrow.musync/media_store'),
        (_) => Completer<String>().future,
      );
      final sw = Stopwatch()..start();
      expect(await MediaStore.sdkInt(), isNull);
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });

  group('J52 — AssistantBridge : fermeture du client possédé', () {
    test('client possédé : fermé, l’appel suivant dit « injoignable »',
        () async {
      final bridge = AssistantBridge();
      bridge.close();
      await expectLater(
        bridge.complete(
          provider: _testProvider(),
          system: 's',
          history: const [],
          userText: 'x',
        ),
        throwsA(
          isA<AiReaderException>().having(
            (e) => e.message,
            'message',
            contains('injoignable'),
          ),
        ),
      );
    });

    test('client injecté : close() ne le ferme pas', () async {
      final fake = _FakeHttpClient((_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '{"answer": "ok"}'},
                },
              ],
            }),
            200,
          ));
      final bridge = AssistantBridge(client: fake);
      bridge.close();
      final out = await bridge.complete(
        provider: _testProvider(),
        system: 's',
        history: const [],
        userText: 'x',
      );
      expect(out, contains('ok'));
    });
  });

  group('J40/J41 — routeur', () {
    testWidgets('batch vide : écran d’erreur, pas un batch vide',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: AppRouter.generateRoute,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).pushNamed(
                AppRoutes.batch,
                arguments: const <Song>[],
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Aucun morceau à traiter.'), findsOneWidget);
    });

    test('route inconnue : settings.name = bibliothèque', () {
      final route = AppRouter.generateRoute(
        const RouteSettings(name: '/storage/emulated/0/x.mp3'),
      );
      expect(route.settings.name, AppRoutes.library);
    });
  });

  group('K69 — tag_mtime_store : seules les valeurs scalaires', () {
    test('null / liste / objet ignorés, int et chaîne gardés', () async {
      final file = File('${tempDir.path}/tag_mtimes.json');
      await file.writeAsString(jsonEncode({
        'a.mp3': null,
        'b.mp3': [1, 2],
        'c.mp3': {'x': 1},
        'd.mp3': 123456,
        'e.mp3': '111:222',
      }));
      final loaded = await TagMtimeStore(root: tempDir).load();
      expect(loaded, {'d.mp3': '123456', 'e.mp3': '111:222'});
    });
  });
}

// ── Helpers : fixtures ────────────────────────────────────────────────────

SongModel _fakeSongModel(int id, String path, {int? duration}) => SongModel({
      '_id': id,
      '_data': path,
      '_uri': 'content://media/$id',
      '_display_name': 'titre$id.mp3',
      '_display_name_wo_ext': 'titre$id',
      '_size': 1000,
      'album': 'Album',
      'album_id': 1,
      'artist': 'Artiste',
      'artist_id': 1,
      'title': 'Titre $id',
      'duration': duration,
      'date_added': 0,
      'is_music': true,
    });

class _FakeAudioQuery extends OnAudioQuery {
  final List<SongModel> songs;
  _FakeAudioQuery(this.songs);

  @override
  Future<List<SongModel>> querySongs({
    SongSortType? sortType,
    OrderType? orderType,
    UriType? uriType,
    bool? ignoreCase,
    String? path,
  }) async =>
      songs;
}

/// Un premier frame MP3 MPEG-1 Layer III à 44,1 kHz avec en-tête Xing.
Uint8List _xingFrame({required int frameCount}) {
  final bytes = <int>[
    0xFF, 0xFB, 0x90, 0x00, // en-tête de trame (128 kbps, 44,1 kHz)
    ...List.filled(32, 0), // side info stéréo MPEG-1
    ...'Xing'.codeUnits,
    0, 0, 0, 0x01 | 0x02 | 0x08, // flags : trames + octets + qualité
    (frameCount >> 24) & 0xFF,
    (frameCount >> 16) & 0xFF,
    (frameCount >> 8) & 0xFF,
    frameCount & 0xFF,
    0, 0, 0, 0, // byte count
    0, 0, 0, 0, // qualité
    ...'LAME3.100'.codeUnits,
    ...List.filled(12, 0),
    0, 0, 0,
    ...List.filled(12, 0),
  ];
  return Uint8List.fromList(bytes);
}

/// En-tête FLAC minimal : « fLaC » + STREAMINFO (34 octets).
Uint8List _flacHead({required int sampleRate, required int totalSamples}) {
  final info = Uint8List(34);
  // Fréquence : 20 bits aux octets 10-12 (demi-octet haut de 12).
  info[10] = (sampleRate >> 12) & 0xFF;
  info[11] = (sampleRate >> 4) & 0xFF;
  // Octet 12 : 4 bits bas de la fréquence, puis canaux-1 (2, soit 1) et
  // 1 bit haut de bps-1 (16 bits, soit 15).
  info[12] = ((sampleRate & 0x0F) << 4) | (1 << 2) | 0x01;
  // Octet 13 : 3 bits bas de bps-1, puis 4 bits hauts du total.
  info[13] = (0x07 << 5) | ((totalSamples >> 32) & 0x0F);
  info[14] = (totalSamples >> 24) & 0xFF;
  info[15] = (totalSamples >> 16) & 0xFF;
  info[16] = (totalSamples >> 8) & 0xFF;
  info[17] = totalSamples & 0xFF;
  return Uint8List.fromList([
    ...'fLaC'.codeUnits,
    0x00, 0, 0, 34, // bloc STREAMINFO, longueur 34
    ...info,
  ]);
}

List<int> _u32le(int v) => [
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ];

/// En-tête WAV minimal : RIFF + fmt (PCM stéréo 16 bits) + data.
Uint8List _wavHead({required int byteRate, required int dataSize}) {
  final out = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add(_u32le(36 + dataSize))
    ..add('WAVE'.codeUnits)
    ..add('fmt '.codeUnits)
    ..add(_u32le(16))
    ..add([1, 0, 2, 0]) // PCM, stéréo
    ..add(_u32le(44100))
    ..add(_u32le(byteRate))
    ..add([4, 0]) // block align
    ..add([16, 0]) // bits par échantillon
    ..add('data'.codeUnits)
    ..add(_u32le(dataSize))
    ..add(Uint8List(16));
  return out.toBytes();
}

// ── Helpers : ID3 ─────────────────────────────────────────────────────────

class _Id3Frame {
  final String id;
  final List<int> body;
  final int flagsLo;
  const _Id3Frame(this.id, this.body, {this.flagsLo = 0});
}

/// Tag ID3v2 assemblé à la main (tailles v2.3 big-endian, v2.4 synchsafe).
Uint8List _id3TagBytes({
  required int major,
  required List<_Id3Frame> frames,
  int padding = 0,
  int headerFlags = 0,
}) {
  final body = BytesBuilder();
  for (final frame in frames) {
    final size = frame.body.length;
    body.add(ascii.encode(frame.id));
    body.add(
      major == 4
          ? [
              (size >> 21) & 0x7F,
              (size >> 14) & 0x7F,
              (size >> 7) & 0x7F,
              size & 0x7F,
            ]
          : [
              (size >> 24) & 0xFF,
              (size >> 16) & 0xFF,
              (size >> 8) & 0xFF,
              size & 0xFF,
            ],
    );
    body.add([0, frame.flagsLo]);
    body.add(frame.body);
  }
  body.add(List<int>.filled(padding, 0));
  final bodyBytes = body.toBytes();
  return (BytesBuilder()
        ..add(ascii.encode('ID3'))
        ..add([major, 0, headerFlags])
        ..add([
          (bodyBytes.length >> 21) & 0x7F,
          (bodyBytes.length >> 14) & 0x7F,
          (bodyBytes.length >> 7) & 0x7F,
          bodyBytes.length & 0x7F,
        ])
        ..add(bodyBytes))
      .toBytes();
}

/// Tag dont une frame déclare 50 octets de corps pour 10 présents.
Uint8List _id3TruncatedTag() {
  final body = BytesBuilder()
    ..add(ascii.encode('TIT2'))
    ..add([0, 0, 0, 50]) // taille v2.3 big-endian
    ..add([0, 0]) // flags
    ..add([0, ...'Titr'.codeUnits]); // 5 octets de corps seulement
  final bodyBytes = body.toBytes();
  return (BytesBuilder()
        ..add(ascii.encode('ID3'))
        ..add([3, 0, 0])
        ..add([
          (bodyBytes.length >> 21) & 0x7F,
          (bodyBytes.length >> 14) & 0x7F,
          (bodyBytes.length >> 7) & 0x7F,
          bodyBytes.length & 0x7F,
        ])
        ..add(bodyBytes))
      .toBytes();
}

/// En-tête ID3 seul, taille déclarée (1000) bien au-delà du fichier.
Uint8List _id3OversizedTag() {
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    3, 0, 0,
    0, 0, 0x07, 0x68, // 1000 synchsafe
    ...List.filled(40, 0),
  ]);
}

TrackMetadata _metadata({int? trackNumber, int? trackTotal}) => (
      title: null,
      artist: null,
      album: null,
      albumArtist: null,
      genre: null,
      year: null,
      trackNumber: trackNumber,
      trackTotal: trackTotal,
      discNumber: null,
      discTotal: null,
      composer: null,
      comment: null,
      artwork: null,
    );

// ── Helpers : M4A ─────────────────────────────────────────────────────────

Uint8List _u32(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.big);
  return b.buffer.asUint8List();
}

Uint8List _u64(int v) {
  final b = ByteData(8)..setUint64(0, v, Endian.big);
  return b.buffer.asUint8List();
}

int _readU32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

Uint8List _atom(String type, Uint8List payload) {
  final out = BytesBuilder()
    ..add(_u32(8 + payload.length))
    ..add(type.codeUnits)
    ..add(payload);
  return out.toBytes();
}

Uint8List _atomBytes(List<int> type, Uint8List payload) {
  final out = BytesBuilder()
    ..add(_u32(8 + payload.length))
    ..add(type)
    ..add(payload);
  return out.toBytes();
}

Uint8List _stcoAtom(List<int> entries) {
  final body = BytesBuilder()
    ..add(_u32(0))
    ..add(_u32(entries.length));
  for (final e in entries) {
    body.add(_u32(e));
  }
  return _atom('stco', body.toBytes());
}

Uint8List _ftyp() => _atom(
      'ftyp',
      Uint8List.fromList([...'isom'.codeUnits, 0, 0, 0, 0, ...'isom'.codeUnits]),
    );

/// M4A minimal avec un `mvhd` (v0 ou v1).
Uint8List _m4aWithMvhd({
  required int timescale,
  required int duration,
  int version = 0,
}) {
  final mvhdBody = BytesBuilder()..add([version, 0, 0, 0]);
  if (version == 1) {
    mvhdBody
      ..add(Uint8List(8))
      ..add(Uint8List(8))
      ..add(_u32(timescale))
      ..add(_u64(duration));
  } else {
    mvhdBody
      ..add(Uint8List(4))
      ..add(Uint8List(4))
      ..add(_u32(timescale))
      ..add(_u32(duration));
  }
  final moov = _atom('moov', _atom('mvhd', mvhdBody.toBytes()));
  return Uint8List.fromList([
    ..._ftyp(),
    ...moov,
    ..._atom('mdat', Uint8List(10)),
  ]);
}

/// Atome `©lyr` dont le `data` porte le type [type] et les octets [textBytes].
Uint8List _lyrAtomBytes(List<int> textBytes, {required int type}) {
  final data = BytesBuilder()
    ..add(_u32(16 + textBytes.length))
    ..add('data'.codeUnits)
    ..add(_u32(type))
    ..add(_u32(0))
    ..add(textBytes);
  return _atomBytes([0xA9, 0x6C, 0x79, 0x72], data.toBytes());
}

Uint8List _m4aWithLyr(Uint8List lyrAtom) {
  final ilst = _atom('ilst', lyrAtom);
  final meta = _atom(
    'meta',
    Uint8List.fromList([0, 0, 0, 0, ...ilst]),
  );
  final udta = _atom('udta', meta);
  final trak = _atom(
    'trak',
    _atom('mdia', _atom('minf', _atom('stbl', _stcoAtom([1000, 2000])))),
  );
  final moov = _atom(
    'moov',
    Uint8List.fromList([...trak, ...udta]),
  );
  return Uint8List.fromList([
    ..._ftyp(),
    ...moov,
    ..._atom('mdat', Uint8List(100)),
  ]);
}

Uint8List _m4aWithLyrUtf16(String text) {
  final units = <int>[0xFE, 0xFF]; // BOM big-endian
  for (final unit in text.codeUnits) {
    units.addAll([unit >> 8, unit & 0xFF]);
  }
  return _m4aWithLyr(_lyrAtomBytes(units, type: 2));
}

Uint8List _m4aWithLyrBytes(List<int> bytes, {required int type}) =>
    _m4aWithLyr(_lyrAtomBytes(bytes, type: type));

/// Cherche un atome enfant direct ; rend (offset, taille) ou null.
({int offset, int size})? _findChild(
  Uint8List bytes,
  int start,
  int end,
  List<int> want, {
  int skip = 0,
}) {
  var o = start + skip;
  while (o + 8 <= end) {
    final size = _readU32(bytes, o);
    final type = bytes.sublist(o + 4, o + 8);
    if (size < 8 || o + size > end) break;
    var match = true;
    for (var i = 0; i < 4; i++) {
      if (type[i] != want[i]) match = false;
    }
    if (match) return (offset: o, size: size);
    o += size;
  }
  return null;
}

List<int> _stcoEntries(Uint8List bytes) {
  final moov = _findChild(bytes, 0, bytes.length, 'moov'.codeUnits)!;
  final moovEnd = moov.offset + moov.size;
  final trak = _findChild(bytes, moov.offset + 8, moovEnd, 'trak'.codeUnits)!;
  final mdia = _findChild(
    bytes, trak.offset + 8, trak.offset + trak.size, 'mdia'.codeUnits)!;
  final minf = _findChild(
    bytes, mdia.offset + 8, mdia.offset + mdia.size, 'minf'.codeUnits)!;
  final stbl = _findChild(
    bytes, minf.offset + 8, minf.offset + minf.size, 'stbl'.codeUnits)!;
  final stco = _findChild(
    bytes, stbl.offset + 8, stbl.offset + stbl.size, 'stco'.codeUnits)!;
  final base = stco.offset + 8;
  final count = _readU32(bytes, base + 4);
  return [for (var i = 0; i < count; i++) _readU32(bytes, base + 8 + i * 4)];
}

int _moovSize(Uint8List bytes) =>
    _findChild(bytes, 0, bytes.length, 'moov'.codeUnits)!.size;

/// M4A `ftyp, mdat, moov` : moov après le mdat, avec un chunk dans le mdat
/// (avant moov) et un après moov.
({Uint8List bytes, int chunkBefore, int chunkAfter}) _mdatFirstM4a() {
  Uint8List buildWith(List<int> entries) {
    final stbl = _atom('stbl', _stcoAtom(entries));
    final minf = _atom('minf', stbl);
    final mdia = _atom('mdia', minf);
    final trak = _atom('trak', mdia);
    final moov = _atom('moov', trak);
    final mdat = _atom('mdat', Uint8List(100));
    return Uint8List.fromList([..._ftyp(), ...mdat, ...moov]);
  }

  final probe = buildWith([0, 0]);
  final moov = _findChild(probe, 0, probe.length, 'moov'.codeUnits)!;
  final chunkBefore = 20 + 8 + 10; // dans le payload du mdat
  final chunkAfter = moov.offset + moov.size + 50;
  return (
    bytes: buildWith([chunkBefore, chunkAfter]),
    chunkBefore: chunkBefore,
    chunkAfter: chunkAfter,
  );
}

// ── Helpers : pont IA ─────────────────────────────────────────────────────

AiProviderConfig _testProvider() => AiProviderConfig(
      id: 't',
      name: 'Test',
      kind: AiProviderKind.openAiCompatible,
      baseUrl: 'https://test.local/v1',
      model: 'modele-test',
      apiKey: 'cle-test',
    );

class _FakeHttpClient extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest request) onRequest;
  _FakeHttpClient(this.onRequest);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final r = await onRequest(request);
    return http.StreamedResponse(
      Stream.value(r.bodyBytes),
      r.statusCode,
      headers: r.headers,
    );
  }
}
