import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/lyrics/ui/lyrics_search_screen.dart';

LyricsSearchResult _result(String source, String title) => LyricsSearchResult(
  source: source,
  title: title,
  artist: 'Trevor Daniel',
  syncedLyrics: SyncedLyrics([
    const LyricLine(timestamp: Duration(seconds: 1), text: 'La la'),
  ]),
  confidence: 0.9,
);

class _FastSource extends LyricsSource {
  var calls = 0;

  @override
  String get name => 'Rapide';

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    calls++;
    return [_result(name, title)];
  }
}

class _HangingSource extends LyricsSource {
  var calls = 0;
  final Completer<List<LyricsSearchResult>> gate = Completer();

  @override
  String get name => 'Lente';

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) {
    calls++;
    return gate.future;
  }
}

Song _song() => Song(
  id: 1,
  title: 'Falling',
  artist: 'Trevor Daniel',
  album: 'Nicotine',
  duration: 159000,
  filePath: '/musique/Trevor Daniel - Falling.mp3',
);

void main() {
  testWidgets('annuler coupe le chargement et garde les résultats',
      (tester) async {
    final fast = _FastSource();
    final hanging = _HangingSource();
    late WidgetRef ref;
    await tester.pumpWidget(
      MaterialApp(
        home: ProviderScope(
          overrides: [
            lyricsRepositoryProvider.overrideWithValue(
              LyricsRepository(sources: [fast, hanging]),
            ),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pump();

    // Recherche lancée sans l'attendre : la source lente ne répond jamais.
    unawaited(
      performLyricsSearch(ref, title: 'Falling', artist: 'Trevor Daniel'),
    );
    await tester.pump();
    await tester.pump();
    // La source rapide a répondu, la lente retient le chargement.
    expect(ref.read(lyricsSearchLoadingProvider), isTrue);
    expect(ref.read(lyricsSearchResultsProvider), hasLength(1));

    cancelLyricsSearch(ref);
    await tester.pump();
    expect(ref.read(lyricsSearchLoadingProvider), isFalse);
    expect(ref.read(lyricsSearchCancelledProvider), isTrue);
    expect(ref.read(lyricsSearchResultsProvider), hasLength(1));
    expect(ref.read(lyricsSearchErrorProvider), isNull);

    // La source lente finit par répondre (vide) : rien ne doit bouger,
    // et surtout aucune nouvelle recherche ne doit repartir.
    hanging.gate.complete([]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(ref.read(lyricsSearchLoadingProvider), isFalse);
    expect(ref.read(lyricsSearchResultsProvider), hasLength(1));
    expect(ref.read(lyricsSearchErrorProvider), isNull);
    expect(fast.calls, 1);
    expect(hanging.calls, 1);

    // Une nouvelle recherche efface la marque d'annulation : le préfixe
    // synchrone de performLyricsSearch la remet à faux avant le premier await.
    // Le future n'est pas attendu : attendre celui d'une recherche annulée
    // par génération bloque le runner testWidgets même une fois le future
    // terminé (reproduit) — l'écran ne l'attend jamais non plus, il réagit
    // aux providers, et le test fait pareil.
    unawaited(
      performLyricsSearch(ref, title: 'Falling', artist: 'Trevor Daniel'),
    );
    expect(ref.read(lyricsSearchCancelledProvider), isFalse);
    expect(ref.read(lyricsSearchLoadingProvider), isTrue);
    cancelLyricsSearch(ref);
    await tester.pump();
    expect(ref.read(lyricsSearchLoadingProvider), isFalse);
  });

  testWidgets(
    'le × dans le cercle annule la recherche et garde les résultats',
    (tester) async {
      final fast = _FastSource();
      final hanging = _HangingSource();
      await tester.pumpWidget(
        MaterialApp(
          home: ProviderScope(
            overrides: [
              lyricsRepositoryProvider.overrideWithValue(
                LyricsRepository(sources: [fast, hanging]),
              ),
            ],
            child: LyricsSearchScreen(song: _song()),
          ),
        ),
      );
      // L'auto-recherche de l'ouverture démarre, la source rapide répond.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Chargement en cours (source lente) : le cercle et son × sont là.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byTooltip('Annuler la recherche'), findsOneWidget);

      await tester.tap(find.byTooltip('Annuler la recherche'));
      await tester.pump();

      // Chargement coupé, le résultat déjà arrivé reste affiché.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.text('Trevor Daniel • Rapide • confiance 90 %'),
        findsOneWidget,
      );

      // La source lente finit par répondre : rien ne repart.
      hanging.gate.complete([]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.text('Trevor Daniel • Rapide • confiance 90 %'),
        findsOneWidget,
      );
      expect(fast.calls, 1);
      expect(hanging.calls, 1);
    },
  );
}
