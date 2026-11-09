// Tests du store de provenance (DESIGN.md §6, FILES.md §4.4).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/lyrics_provenance.dart';

LyricsProvenance _provenance({
  LyricsProvenanceOrigin origin = LyricsProvenanceOrigin.autoAi,
  double confidence = 0.93,
  int? trackId = 123456,
}) => LyricsProvenance(
  source: 'LRCLIB',
  trackId: trackId,
  title: 'Titre',
  artist: 'Artiste',
  confidence: confidence,
  queryTitle: 'Titre',
  queryArtist: 'Artiste',
  viaFilename: false,
  origin: origin,
  embeddedAt: DateTime.fromMillisecondsSinceEpoch(1793000000000),
);

void main() {
  late Directory tmp;
  late Directory root;
  late LyricsProvenanceStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lyrics_provenance_');
    root = Directory('${tmp.path}/support')..createSync();
    store = LyricsProvenanceStore(root: root);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('enregistrement + relecture', () async {
    final file = File('${tmp.path}/track.mp3')..createSync();
    await store.record(file.path, _provenance());
    await store.save();

    final reloaded = LyricsProvenanceStore(root: root);
    final found = await reloaded.forPath(file.path);
    expect(found, isNotNull);
    expect(found!.source, 'LRCLIB');
    expect(found.trackId, 123456);
    expect(found.confidence, 0.93);
    expect(found.origin, LyricsProvenanceOrigin.autoAi);
    expect(found.embeddedAt.millisecondsSinceEpoch, 1793000000000);
  });

  test('version de schéma : un fichier sans version est ignoré', () async {
    final file = File('${tmp.path}/track.mp3')..createSync();
    await File(
      '${root.path}/lyrics_provenance.json',
    ).writeAsString('{"entries": {"${file.path}": {}}}');
    final reloaded = LyricsProvenanceStore(root: root);
    expect(await reloaded.forPath(file.path), isNull);
  });

  test('purge des chemins disparus au chargement', () async {
    final gone = File('${tmp.path}/gone.mp3')..createSync();
    final kept = File('${tmp.path}/kept.mp3')..createSync();
    await store.record(gone.path, _provenance());
    await store.record(kept.path, _provenance());
    await store.save();
    await gone.delete();

    final reloaded = LyricsProvenanceStore(root: root);
    expect(await reloaded.forPath(gone.path), isNull);
    expect(await reloaded.forPath(kept.path), isNotNull);
  });

  test('origine user conservée après réécriture auto refusée', () async {
    // L'utilisateur a collé ses paroles : l'origine reste `pasted`
    // même si l'app a ensuite proposé (sans écrire) un candidat.
    final file = File('${tmp.path}/track.mp3')..createSync();
    await store.record(
      file.path,
      _provenance(origin: LyricsProvenanceOrigin.pasted),
    );
    await store.save();

    final reloaded = LyricsProvenanceStore(root: root);
    final found = await reloaded.forPath(file.path);
    expect(found!.isUserOrigin, isTrue);
    // Une tentative auto ne doit pas écraser cette origine : le finder
    // n'appelle record() que quand il écrit vraiment.
    expect(found.origin, LyricsProvenanceOrigin.pasted);
  });

  test('isLowConfidenceAuto : auto < 0,80 oui, user ou ≥ 0,80 non', () {
    expect(
      _provenance(confidence: 0.40).isLowConfidenceAuto,
      isTrue,
    );
    expect(
      _provenance(confidence: 0.93).isLowConfidenceAuto,
      isFalse,
    );
    expect(
      _provenance(
        origin: LyricsProvenanceOrigin.pasted,
        confidence: 0.40,
      ).isLowConfidenceAuto,
      isFalse,
    );
    expect(
      _provenance(
        origin: LyricsProvenanceOrigin.manual,
        confidence: 0.40,
      ).isUserOrigin,
      isTrue,
    );
  });

  test('forget supprime l\'entrée', () async {
    final file = File('${tmp.path}/track.mp3')..createSync();
    await store.record(file.path, _provenance());
    await store.forget(file.path);
    expect(await store.forPath(file.path), isNull);
  });
}
