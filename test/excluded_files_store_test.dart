/// Tests d'ExcludedFilesStore : normalisation, appartenance exacte (jamais de
/// préfixe), persistance.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/excluded_files_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('normalise', () {
    test('rognage des espaces', () {
      expect(
        ExcludedFilesStore.normalise('  /Musique/a.mp3  '),
        '/Musique/a.mp3',
      );
    });

    test('vide après rognage', () {
      expect(ExcludedFilesStore.normalise('   '), isEmpty);
    });
  });

  group('isExcluded', () {
    test('correspondance exacte', () {
      expect(
        ExcludedFilesStore.isExcluded('/Musique/a.mp3', ['/Musique/a.mp3']),
        isTrue,
      );
    });

    test('jamais de préfixe : a.mp3x n’est pas exclu par a.mp3', () {
      expect(
        ExcludedFilesStore.isExcluded('/Musique/a.mp3x', ['/Musique/a.mp3']),
        isFalse,
      );
    });

    test('le dossier parent n’exclut pas le fichier', () {
      expect(
        ExcludedFilesStore.isExcluded('/Musique/a.mp3', ['/Musique']),
        isFalse,
      );
    });

    test('insensible à la casse', () {
      expect(
        ExcludedFilesStore.isExcluded('/musique/A.MP3', ['/Musique/a.mp3']),
        isTrue,
      );
    });

    test('liste vide : rien d’exclu', () {
      expect(ExcludedFilesStore.isExcluded('/Musique/a.mp3', []), isFalse);
    });
  });

  group('persistance', () {
    test('aller-retour load/save', () async {
      SharedPreferences.setMockInitialValues({});
      const store = ExcludedFilesStore();
      await store.save(['/Musique/b.mp3', '/Musique/a.mp3']);
      expect(await store.load(), ['/Musique/a.mp3', '/Musique/b.mp3']);
    });

    test('doublons et vides éliminés', () async {
      SharedPreferences.setMockInitialValues({});
      const store = ExcludedFilesStore();
      await store.save(['/Musique/a.mp3', '  /Musique/a.mp3 ', '']);
      expect(await store.load(), ['/Musique/a.mp3']);
    });
  });
}
