// Tests de SweepMemory : identité mémorisée + invalidation sur retag.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/sweep_memory.dart';

void main() {
  late Directory tmp;
  late SweepMemory memory;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sweep_memory_');
    memory = SweepMemory(root: tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('un raté confirmé est cru 14 jours pour la même identité', () async {
    await memory.markMissed(
      '/musique/1.mp3',
      title: 'Titre',
      artist: 'Artiste',
    );
    await memory.save();
    expect(
      await memory.recentlyMissed(
        '/musique/1.mp3',
        title: 'Titre',
        artist: 'Artiste',
      ),
      isTrue,
    );
  });

  test('un morceau retaggé n\'est plus cru raté', () async {
    await memory.markMissed(
      '/musique/1.mp3',
      title: '09',
      artist: 'Artiste Réel',
    );
    await memory.save();
    expect(
      await memory.recentlyMissed(
        '/musique/1.mp3',
        title: 'Vrai Titre',
        artist: 'Artiste Réel',
      ),
      isFalse,
    );
    expect(
      await memory.recentlyMissed(
        '/musique/1.mp3',
        title: '09',
        artist: 'Artiste Réel',
      ),
      isTrue,
    );
  });

  test('ancienne entrée (entier seul) : comportement inchangé', () async {
    final at = DateTime.now().millisecondsSinceEpoch;
    await File(
      '${tmp.path}/lyrics_sweep_misses.json',
    ).writeAsString('{"/musique/1.mp3": $at}');
    final reloaded = SweepMemory(root: tmp);
    expect(await reloaded.recentlyMissed('/musique/1.mp3'), isTrue);
  });

  test('chemin jamais marqué → faux', () async {
    expect(await memory.recentlyMissed('/musique/1.mp3'), isFalse);
  });
}
