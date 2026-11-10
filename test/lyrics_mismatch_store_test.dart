// Tests du store « non correspondant » (patron SweepMemory, sans expiration).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/lyrics_mismatch_store.dart';

void main() {
  late Directory tmp;
  late Directory root;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lyrics_mismatch_store_');
    root = Directory('${tmp.path}/support')..createSync();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  LyricsMismatchStore store() => LyricsMismatchStore(root: root);

  test('marque puis démarque', () async {
    final s = store();
    expect(
      await s.isMismatched('/m/1.mp3', title: 'Titre', artist: 'Artiste'),
      isFalse,
    );
    await s.markMismatched('/m/1.mp3', title: 'Titre', artist: 'Artiste');
    await s.save();
    expect(
      await s.isMismatched('/m/1.mp3', title: 'Titre', artist: 'Artiste'),
      isTrue,
    );
    await s.unmark('/m/1.mp3');
    await s.save();
    expect(
      await s.isMismatched('/m/1.mp3', title: 'Titre', artist: 'Artiste'),
      isFalse,
    );
  });

  test('la marque survit à un redémarrage (nouvelle instance, même fichier)',
      () async {
    final s = store();
    await s.markMismatched('/m/2.mp3', title: 'Titre', artist: 'Artiste');
    await s.save();
    final reloaded = LyricsMismatchStore(root: root);
    expect(
      await reloaded.isMismatched(
        '/m/2.mp3',
        title: 'Titre',
        artist: 'Artiste',
      ),
      isTrue,
    );
  });

  test('la marque ne s’applique plus après retag (titre ou artiste changé)',
      () async {
    final s = store();
    await s.markMismatched(
      '/m/3.mp3',
      title: 'Ancien titre',
      artist: 'Artiste',
    );
    await s.save();
    expect(
      await s.isMismatched(
        '/m/3.mp3',
        title: 'Nouveau titre',
        artist: 'Artiste',
      ),
      isFalse,
    );
    expect(
      await s.isMismatched(
        '/m/3.mp3',
        title: 'Ancien titre',
        artist: 'Autre',
      ),
      isFalse,
    );
    expect(
      await s.isMismatched(
        '/m/3.mp3',
        title: 'Ancien titre',
        artist: 'Artiste',
      ),
      isTrue,
    );
  });

  test('la marque n’expire jamais', () async {
    final file = File('${root.path}/lyrics_mismatches.json');
    await file.writeAsString(
      jsonEncode({
        '/m/4.mp3': {
          'at': DateTime.now()
              .subtract(const Duration(days: 365))
              .millisecondsSinceEpoch,
          'title': 'Titre',
          'artist': 'Artiste',
        },
      }),
    );
    expect(
      await store().isMismatched(
        '/m/4.mp3',
        title: 'Titre',
        artist: 'Artiste',
      ),
      isTrue,
    );
  });

  test('démarquer un chemin inconnu ne fait rien', () async {
    final s = store();
    await s.unmark('/m/inconnu.mp3');
    await s.save();
    expect(await s.isMismatched('/m/inconnu.mp3'), isFalse);
  });

  test('fichier illisible = aucun morceau marqué', () async {
    final file = File('${root.path}/lyrics_mismatches.json');
    await file.writeAsString('ceci n’est pas du json');
    expect(await store().isMismatched('/m/1.mp3'), isFalse);
  });
}
