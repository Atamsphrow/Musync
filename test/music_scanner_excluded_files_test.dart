/// Test du filtre « fichiers exclus » de MusicScanner.
///
/// Le scan saute les fichiers listés dans ExcludedFilesStore (raison
/// « Fichier exclu »), sans toucher au reste — ni au filtre dossiers.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/excluded_dirs_store.dart';
import 'package:musync/features/library/data/excluded_files_store.dart';
import 'package:musync/features/library/data/music_scanner.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

SongModel _fakeSong(int id, String path) => SongModel({
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
      'duration': 180000,
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

void main() {
  test('un fichier exclu est sauté avec la raison « Fichier exclu »', () async {
    SharedPreferences.setMockInitialValues({
      ExcludedFilesStore.prefsKey: ['/Musique/banni.mp3'],
    });
    final scanner = MusicScanner(
      audioQuery: _FakeAudioQuery([
        _fakeSong(1, '/Musique/garde.mp3'),
        _fakeSong(2, '/Musique/banni.mp3'),
      ]),
    );

    final kept = await scanner.scanAllSongs();

    expect(kept.map((s) => s.filePath), ['/Musique/garde.mp3']);
    expect(scanner.lastIgnored.map((i) => i.path), ['/Musique/banni.mp3']);
    expect(scanner.lastIgnored.single.reason, 'Fichier exclu');
  });

  test('le filtre dossiers continue de marcher à côté', () async {
    SharedPreferences.setMockInitialValues({
      ExcludedDirsStore.prefsKey: ['/Musique/DossierBanni'],
      ExcludedFilesStore.prefsKey: ['/Musique/banni.mp3'],
    });
    final scanner = MusicScanner(
      audioQuery: _FakeAudioQuery([
        _fakeSong(1, '/Musique/garde.mp3'),
        _fakeSong(2, '/Musique/banni.mp3'),
        _fakeSong(3, '/Musique/DossierBanni/cache.mp3'),
      ]),
    );

    final kept = await scanner.scanAllSongs();

    expect(kept.map((s) => s.filePath), ['/Musique/garde.mp3']);
    expect(
      {for (final i in scanner.lastIgnored) i.path: i.reason},
      {
        '/Musique/banni.mp3': 'Fichier exclu',
        '/Musique/DossierBanni/cache.mp3': 'Dossier exclu',
      },
    );
  });
}
