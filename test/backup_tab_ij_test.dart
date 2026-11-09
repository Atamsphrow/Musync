/// Correctifs du lot I (basses confirmées, onglet Historique) :
/// - I16 : l'erreur de chargement affiche un message convivial, pas
///         l'exception brute.
/// - I18 : la taille totale somme TOUTES les étapes, pas seulement la plus
///         récente par piste.
/// - I19 : l'état vide ne rend plus un `Center(SizedBox.shrink())` redondant
///         (l'en-tête dit déjà « Aucune écriture enregistrée. »).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/tag_backup.dart';
import 'package:musync/features/settings/providers/backup_provider.dart';
import 'package:musync/features/settings/ui/backup_tab.dart';

TagBackup _backup(String path, int bytes, DateTime at) => TagBackup(
      filePath: path,
      writtenAt: at,
      tagBytes: bytes,
      writtenMtime: 0,
      storedAs: 'b$bytes',
    );

Future<void> _pump(
  WidgetTester tester,
  Future<List<TagBackup>> Function() load,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tagBackupsProvider.overrideWith((ref) => load())],
      child: const MaterialApp(home: Scaffold(body: BackupTab())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('I18 la taille totale somme toutes les étapes', (tester) async {
    // Deux étapes (1024 + 2048 o) pour la même piste : l'en-tête doit
    // afficher 3 Ko, pas 1 Ko (la seule étape la plus récente).
    await _pump(tester, () async => [
          _backup('/Musique/a.mp3', 2048, DateTime(2026, 11, 9, 10, 0)),
          _backup('/Musique/a.mp3', 1024, DateTime(2026, 11, 8, 10, 0)),
        ]);
    expect(find.textContaining('1 morceau(x) restaurable(s)'), findsOneWidget);
    expect(find.textContaining('3 Ko'), findsOneWidget);
  });

  testWidgets('I16 l’erreur de chargement est conviviale', (tester) async {
    await _pump(tester, () async => throw Exception('boom interne'));
    expect(find.textContaining('Impossible de charger'), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('I19 état vide : en-tête seul, sans crash', (tester) async {
    await _pump(tester, () async => []);
    expect(find.text('Aucune écriture enregistrée.'), findsOneWidget);
  });
}
