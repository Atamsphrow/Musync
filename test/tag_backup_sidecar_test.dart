// Le sidecar .lrc du tap « Paroles incorrectes » : sauvegardé par
// `capture`, supprimé par le tap, restauré par « Annuler ».
//
// Le flux testé est celui du tap : capture → écriture sans paroles →
// markWritten → suppression du sidecar → restore. Le morceau est un
// MP3 construit par Id3Writer, le sidecar un fichier texte à côté.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/id3/tag_backup.dart';

const _lrcText = '[00:01.00]Une\n[00:04.00]Deux\n';

final _lyrics = SyncedLyrics([
  const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
  const LyricLine(timestamp: Duration(seconds: 4), text: 'Deux'),
]);

void main() {
  late Directory tempDir;
  late TagBackupStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musync_sidecar_');
    store = TagBackupStore(root: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> makeTrack(String name) async {
    final path = '${tempDir.path}${Platform.pathSeparator}$name';
    await File(path).writeAsBytes(
      Uint8List.fromList(List<int>.generate(8192, (i) => (i * 7) % 256)),
    );
    await Id3Writer.writeLyrics(path, synced: _lyrics);
    return path;
  }

  Future<String> makeSidecar(String trackPath, String ext) async {
    final dot = trackPath.lastIndexOf('.');
    final path = '${trackPath.substring(0, dot)}$ext';
    await File(path).writeAsString(_lrcText);
    return path;
  }

  Future<List<FileSystemEntity>> backupFiles() async {
    final dir = Directory(
      '${tempDir.path}${Platform.pathSeparator}tag_backups',
    );
    if (!await dir.exists()) return const [];
    return dir.list().toList();
  }

  test('capture sauvegarde le sidecar, restore le remet', () async {
    final path = await makeTrack('track.mp3');
    final sidecarPath = await makeSidecar(path, '.lrc');
    final before = await File(path).readAsBytes();

    expect(await store.capture(path), isTrue);
    var entry = (await store.list()).single;
    expect(entry.sidecarStoredAs, isNotNull);
    expect(entry.sidecarPath, sidecarPath);

    // Le tap : écriture sans paroles, puis suppression du sidecar.
    await Id3Writer.writeLyrics(path);
    expect(
      Id3Reader.readLyricsFromBytes(await File(path).readAsBytes()).synced,
      isNull,
    );
    await store.markWritten(path);
    // markWritten réécrit l'index : les champs sidecar doivent survivre.
    entry = (await store.list()).single;
    expect(entry.sidecarStoredAs, isNotNull);
    expect(entry.sidecarPath, sidecarPath);

    expect(await store.deleteSidecar(path), sidecarPath);
    expect(await File(sidecarPath).exists(), isFalse);

    await store.restore(path);

    expect(await File(path).readAsBytes(), before);
    expect(await File(sidecarPath).readAsString(), _lrcText);
  });

  test('restore ne remplace pas un sidecar recréé entre-temps', () async {
    final path = await makeTrack('track.mp3');
    final sidecarPath = await makeSidecar(path, '.lrc');

    await store.capture(path);
    await Id3Writer.writeLyrics(path);
    await store.markWritten(path);
    await store.deleteSidecar(path);

    // Musicolet réécrit un sidecar avant « Annuler ».
    const newText = '[00:02.00]Nouveau\n';
    await File(sidecarPath).writeAsString(newText);

    await store.restore(path);

    expect(await File(sidecarPath).readAsString(), newText);
  });

  test('sans sidecar : rien à sauvegarder ni à supprimer', () async {
    final path = await makeTrack('track.mp3');

    expect(await store.capture(path), isTrue);
    final entry = (await store.list()).single;
    expect(entry.sidecarStoredAs, isNull);
    expect(entry.sidecarPath, isNull);
    expect(await store.deleteSidecar(path), isNull);
  });

  test('extension .LRC majuscule : retrouvée et restaurée telle quelle',
      () async {
    final path = await makeTrack('track.mp3');
    final sidecarPath = await makeSidecar(path, '.LRC');

    await store.capture(path);
    final entry = (await store.list()).single;
    expect(entry.sidecarPath, sidecarPath);

    expect(await store.deleteSidecar(path), sidecarPath);
    await Id3Writer.writeLyrics(path);
    await store.markWritten(path);
    await store.restore(path);

    expect(await File(sidecarPath).readAsString(), _lrcText);
  });

  test('discardLatest supprime aussi le blob sidecar', () async {
    final path = await makeTrack('track.mp3');
    await makeSidecar(path, '.lrc');

    await store.capture(path);
    expect(
      (await backupFiles()).where((f) => f.path.endsWith('.lrc')),
      hasLength(1),
    );

    await store.discardLatest(path);

    expect(
      (await backupFiles()).where((f) => f.path.endsWith('.lrc')),
      isEmpty,
    );
    expect(await store.list(), isEmpty);
  });

  test('les champs sidecar survivent au JSON de l’index', () async {
    final path = await makeTrack('track.mp3');
    await makeSidecar(path, '.lrc');

    await store.capture(path);
    final entry = (await store.list()).single;

    final roundTripped = TagBackup.fromJson(entry.toJson());
    expect(roundTripped?.sidecarStoredAs, entry.sidecarStoredAs);
    expect(roundTripped?.sidecarPath, entry.sidecarPath);

    // Une ancienne entrée, sans les champs, se lit quand même.
    final legacy = TagBackup.fromJson({
      'filePath': path,
      'writtenAt': DateTime.now().toIso8601String(),
      'tagBytes': 10,
      'writtenMtime': 0,
      'storedAs': 'abc.tag',
    });
    expect(legacy?.sidecarStoredAs, isNull);
    expect(legacy?.sidecarPath, isNull);
  });
}
