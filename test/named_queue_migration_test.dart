// M121 : migration des ids FNV-1a 32 bits vers 64 bits.
//
// Les files nommées sérialisent les morceaux complets (id + chemin) : un id
// stocké seul ne se convertit pas, mais le chemin dont il dérive est là
// aussi — la migration recalcule l'id depuis le chemin, côté iOS seulement.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/data/music_scanner.dart';
import 'package:musync/features/player/data/named_queue.dart';

/// L'ancien hash, recopié ici pour que le test prouve la migration d'une
/// valeur réellement stockée avant le changement (32 bits), pas d'une
/// valeur inventée.
int oldStableIdForPath(String path) {
  var hash = 0x811c9dc5;
  for (final unit in path.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

void main() {
  test('un id 32 bits stocké devient le nouvel id 64 bits sur iOS', () {
    final stored = oldStableIdForPath('/docs/a.mp3');
    expect(stored, 0x445f4041);

    final migrated =
        migrateStoredSongId(stored, '/docs/a.mp3', isIOS: true);

    expect(migrated, MusicScanner.stableIdForPath('/docs/a.mp3'));
    expect(migrated, isNot(stored));
    expect(migrated, greaterThan(0));
  });

  test('côté Android l\'id stocké est conservé tel quel', () {
    expect(
      migrateStoredSongId(12345, '/docs/a.mp3', isIOS: false),
      12345,
    );
    // Même un ancien id iOS ne serait pas touché sur Android : là-bas
    // l'id est celui de MediaStore, pas un hash du chemin.
    expect(
      migrateStoredSongId(0x445f4041, '/docs/a.mp3', isIOS: false),
      0x445f4041,
    );
  });

  test('sans chemin, l\'id stocké est conservé (rien à recalculer)', () {
    expect(
      migrateStoredSongId(0x445f4041, '', isIOS: true),
      0x445f4041,
    );
  });

  test('le round-trip d\'une file conserve ses morceaux', () {
    const queue = NamedQueue(
      id: 'q1',
      name: 'Test',
      songs: [
        Song(
          id: 287547360281525889,
          title: 'Titre',
          artist: 'Artiste',
          album: 'Album',
          duration: 180000,
          filePath: '/docs/a.mp3',
        ),
      ],
    );
    final restored = NamedQueue.fromJson(queue.toJson());
    expect(restored.songs.single.id, queue.songs.single.id);
    expect(restored.songs.single.filePath, '/docs/a.mp3');
  });
}
