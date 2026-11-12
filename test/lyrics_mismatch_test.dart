// Tests du bouton « Paroles incorrectes » : le finder saute les morceaux
// marqués, et une écriture manuelle de vraies paroles efface la marque.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/id3/tag_backup.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/data/ai_lyrics_finder.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_mismatch_store.dart';
import 'package:musync/features/lyrics/data/lyrics_provenance.dart';
import 'package:musync/features/lyrics/data/lyrics_query_resolver.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

Song _song({
  String title = 'Titre',
  String artist = 'Artiste',
  String album = '',
  int duration = 180000,
  String filePath = '/musique/1.mp3',
}) => Song(
  id: 1,
  title: title,
  artist: artist,
  album: album,
  duration: duration,
  filePath: filePath,
);

LyricsSearchResult _hit({
  String title = 'Titre',
  String artist = 'Artiste',
  int? trackId,
  int? durationMs = 180000,
  bool synced = true,
  String text = 'Vraies paroles',
}) => LyricsSearchResult(
  source: 'LRCLIB',
  title: title,
  artist: artist,
  syncedLyrics: synced
      ? SyncedLyrics([
          LyricLine(timestamp: const Duration(seconds: 1), text: text),
        ])
      : null,
  unsyncedLyrics: synced ? null : UnsyncedLyrics(text),
  confidence: 0.0, // le finder rescore, la confiance d'entrée ne compte pas.
  trackId: trackId,
  durationMs: durationMs,
);

FilenameGuess _noGuess(String _) => (artist: '', title: '');

/// Faux dépôt qui compte les recherches et les écritures.
class _CountingRepo extends LyricsRepository {
  _CountingRepo() : super(sources: const []);

  Map<String, List<LyricsSearchResult>> byQueryTitle = {};
  List<LyricsSearchResult> fallback = [];
  final Map<String, LyricsPair> files = {};
  int searches = 0;
  int embeds = 0;

  @override
  Future<List<LyricsSearchResult>> searchAll({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    searches++;
    return byQueryTitle[title] ?? fallback;
  }

  @override
  Future<LyricsPair> readLyrics(String filePath) async =>
      files[filePath] ?? (synced: null, unsynced: null);

  @override
  Future<void> embedLyrics(
    String filePath, {
    SyncedLyrics? synced,
    UnsyncedLyrics? unsynced,
    bool alignToExisting = false,
  }) async {
    embeds++;
    files[filePath] = (synced: synced, unsynced: unsynced);
  }
}

/// Un MP3 minimal (ID3v2.3 + TIT2 + audio) que Id3Writer peut réécrire.
Future<File> _mp3Fixture(Directory dir, String name) async {
  final title = utf8.encode('Titre');
  final frame = BytesBuilder()
    ..add(ascii.encode('TIT2'))
    ..add([0, 0, 0, title.length + 1, 0, 0])
    ..add([0])
    ..add(title);
  final frameBytes = frame.toBytes();
  final audio = Uint8List.fromList(
    List<int>.generate(8192, (i) => (i * 7) % 256),
  );
  final bytes = BytesBuilder()
    ..add(ascii.encode('ID3'))
    ..add([3, 0, 0])
    ..add([
      (frameBytes.length >> 21) & 0x7F,
      (frameBytes.length >> 14) & 0x7F,
      (frameBytes.length >> 7) & 0x7F,
      frameBytes.length & 0x7F,
    ])
    ..add(frameBytes)
    ..add(audio);
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes.toBytes());
  return file;
}

void main() {
  late Directory tmp;
  late Directory root;
  late _CountingRepo repo;
  late LyricsProvenanceStore provenance;
  late LyricsMismatchStore mismatch;
  late TagBackupStore backups;
  late List<String> changed;

  AiLyricsFinder finder() => AiLyricsFinder(
    repository: repo,
    resolver: const LyricsQueryResolver(parseFilename: _noGuess),
    provenance: provenance,
    backups: backups,
    mismatchStore: mismatch,
    fileChanged: changed.add,
    hasWriteAccess: () async => true,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lyrics_mismatch_');
    root = Directory('${tmp.path}/support')..createSync();
    repo = _CountingRepo();
    provenance = LyricsProvenanceStore(root: root);
    mismatch = LyricsMismatchStore(root: root);
    backups = TagBackupStore(root: root);
    changed = [];
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> realFile(String name) async {
    final file = File('${tmp.path}/$name');
    await file.create();
    return file.path;
  }

  group('finder', () {
    test('morceau marqué → aucune recherche, aucune écriture', () async {
      final path = await realFile('1.mp3');
      repo.fallback = [_hit()];
      await mismatch.markMismatched(
        path,
        title: 'Titre',
        artist: 'Artiste',
      );
      await mismatch.save();
      final result = await finder().findFor(_song(filePath: path));
      expect(result.verdict, LyricsFindVerdict.keptExisting);
      expect(result.note, contains('non correspondant'));
      expect(repo.searches, 0);
      expect(repo.embeds, 0);
    });

    test('morceau non marqué → recherche normale', () async {
      final path = await realFile('1.mp3');
      repo.fallback = [_hit()];
      final result = await finder().findFor(_song(filePath: path));
      expect(repo.searches, greaterThan(0));
      expect(result.verdict, LyricsFindVerdict.integrated);
    });

    test('morceau marqué + demande explicite → la recherche tourne', () async {
      final path = await realFile('1.mp3');
      repo.fallback = [_hit()];
      await mismatch.markMismatched(
        path,
        title: 'Titre',
        artist: 'Artiste',
      );
      await mismatch.save();
      // La marque ne bloque que l'automatique : une demande explicite
      // (assistant, recherche manuelle) passe outre.
      final result = await finder().findFor(
        _song(filePath: path),
        explicit: true,
      );
      expect(repo.searches, greaterThan(0));
      expect(result.verdict, LyricsFindVerdict.integrated);
    });

    test('morceau retaggé depuis la marque → plus bloqué', () async {
      final path = await realFile('1.mp3');
      repo.fallback = [_hit()];
      await mismatch.markMismatched(
        path,
        title: 'Ancien titre',
        artist: 'Artiste',
      );
      await mismatch.save();
      final result = await finder().findFor(_song(filePath: path));
      expect(repo.searches, greaterThan(0));
      expect(result.verdict, LyricsFindVerdict.integrated);
    });

    test('démarquer rouvre les téléchargements', () async {
      final path = await realFile('1.mp3');
      repo.fallback = [_hit()];
      await mismatch.markMismatched(
        path,
        title: 'Titre',
        artist: 'Artiste',
      );
      await mismatch.save();
      await mismatch.unmark(path);
      await mismatch.save();
      final result = await finder().findFor(_song(filePath: path));
      expect(result.verdict, LyricsFindVerdict.integrated);
    });
  });

  group('dépôt', () {
    test('écrire de vraies paroles efface la marque', () async {
      final file = await _mp3Fixture(tmp, 'a.mp3');
      final path = file.path;
      final repository = LyricsRepository(
        sources: const [],
        mismatchStore: mismatch,
      );
      await mismatch.markMismatched(
        path,
        title: 'Titre',
        artist: 'Artiste',
      );
      await mismatch.save();
      await repository.embedLyrics(
        path,
        synced: SyncedLyrics([
          LyricLine(
            timestamp: const Duration(seconds: 1),
            text: 'Vraies paroles',
          ),
        ]),
      );
      expect(
        await mismatch.isMismatched(
          path,
          title: 'Titre',
          artist: 'Artiste',
        ),
        isFalse,
      );
      final after = await repository.readLyrics(path);
      expect(after.synced, isNotNull);
      expect(after.synced, isNotEmpty);
    });

    test('supprimer les paroles garde la marque', () async {
      final file = await _mp3Fixture(tmp, 'b.mp3');
      final path = file.path;
      final repository = LyricsRepository(
        sources: const [],
        mismatchStore: mismatch,
      );
      await repository.embedLyrics(
        path,
        synced: SyncedLyrics([
          LyricLine(
            timestamp: const Duration(seconds: 1),
            text: 'Fausses paroles',
          ),
        ]),
      );
      await mismatch.markMismatched(
        path,
        title: 'Titre',
        artist: 'Artiste',
      );
      await mismatch.save();
      await repository.embedLyrics(path);
      final after = await repository.readLyrics(path);
      expect(after.synced == null || after.synced!.isEmpty, isTrue);
      expect(
        after.unsynced == null || after.unsynced!.text.trim().isEmpty,
        isTrue,
      );
      expect(
        await mismatch.isMismatched(
          path,
          title: 'Titre',
          artist: 'Artiste',
        ),
        isTrue,
      );
    });
  });
}
