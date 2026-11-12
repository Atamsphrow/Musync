// Tests du branchement santé ↔ dépôt : une source en panne n'est plus
// interrogée, une source qui a dit « rien » n'est pas re-demandée, et le
// bypass manuel la réinterroge quand même.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/lyrics_source_health.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';

class _FakeSource extends LyricsSource {
  _FakeSource(this._name);

  final String _name;
  @override
  String get name => _name;

  int calls = 0;

  /// Ce que la source renvoie, ou l'exception qu'elle lève.
  List<LyricsSearchResult> Function()? answer;
  LyricsSourceException? failure;

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    calls++;
    if (failure != null) throw failure!;
    return answer?.call() ?? const [];
  }
}

LyricsSearchResult _hit(String source) => LyricsSearchResult(
  source: source,
  title: 'Titre',
  artist: 'Artiste',
  syncedLyrics: SyncedLyrics([
    const LyricLine(timestamp: Duration(seconds: 1), text: 'Paroles'),
  ]),
  unsyncedLyrics: null,
  confidence: 0.9,
);

void main() {
  late DateTime now;
  late LyricsSourceHealth health;
  late _FakeSource a;
  late _FakeSource b;
  late LyricsRepository repository;

  setUp(() {
    now = DateTime(2026, 11, 12, 11, 0);
    health = LyricsSourceHealth(now: () => now);
    a = _FakeSource('SourceA');
    b = _FakeSource('SourceB');
    repository = LyricsRepository(sources: [a, b], health: health);
  });

  Future<List<LyricsSearchResult>> search({
    String title = 'Titre',
    String artist = 'Artiste',
  }) => repository.searchAll(title: title, artist: artist);

  group('disjoncteur', () {
    test('3 échecs : la source n’est plus interrogée', () async {
      a.failure = const LyricsSourceException('SourceA', 'en panne');
      b.answer = () => [_hit('SourceB')];
      await search();
      await search();
      await search();
      expect(a.calls, 3);
      await search();
      expect(a.calls, 3);
      expect(b.calls, 4);
    });

    test('après 10 min : la source est réessayée', () async {
      a.failure = const LyricsSourceException('SourceA', 'en panne');
      b.answer = () => [_hit('SourceB')];
      await search();
      await search();
      await search();
      expect(health.isSetAside('SourceA'), isTrue);
      now = now.add(const Duration(minutes: 10, seconds: 1));
      await search();
      expect(a.calls, 4);
    });

    test('une réponse remet le compteur à zéro', () async {
      a.failure = const LyricsSourceException('SourceA', 'en panne');
      b.answer = () => [_hit('SourceB')];
      await search();
      await search();
      a.failure = null;
      a.answer = () => [_hit('SourceA')];
      await search();
      expect(health.isSetAside('SourceA'), isFalse);
      a.failure = const LyricsSourceException('SourceA', 'en panne');
      a.answer = null;
      await search();
      await search();
      expect(a.calls, 5);
      expect(health.isSetAside('SourceA'), isFalse);
    });

    test('toutes mises de côté : erreur dédiée, pas « Aucun résultat »',
        () async {
      a.failure = const LyricsSourceException('SourceA', 'en panne');
      b.failure = const LyricsSourceException('SourceB', 'en panne');
      // Tant que les sources échouent, c'est l'erreur « toutes en panne »
      // qui remonte (règle existante) — il faut 3 passages pour que le
      // disjoncteur les mette de côté.
      for (var i = 0; i < 3; i++) {
        await expectLater(search(), throwsA(isA<LyricsSourceException>()));
      }
      expect(health.isSetAside('SourceA'), isTrue);
      expect(health.isSetAside('SourceB'), isTrue);
      await expectLater(
        search(),
        throwsA(
          isA<LyricsSourceException>().having(
            (e) => e.message,
            'message',
            contains('mises de côté'),
          ),
        ),
      );
    });
  });

  group('mémo « pas de paroles »', () {
    test('liste vide : pas re-demandée pour la même requête', () async {
      a.answer = () => const [];
      b.answer = () => [_hit('SourceB')];
      await search();
      await search();
      expect(a.calls, 1);
      expect(b.calls, 2);
    });

    test('liste vide : re-demandée pour une autre requête', () async {
      a.answer = () => const [];
      b.answer = () => [_hit('SourceB')];
      await search();
      await search(title: 'Autre titre');
      expect(a.calls, 2);
    });

    test('le mémo expire après 5 min', () async {
      a.answer = () => const [];
      b.answer = () => [_hit('SourceB')];
      await search();
      now = now.add(const Duration(minutes: 5, seconds: 1));
      await search();
      expect(a.calls, 2);
    });

    test('oublier la requête : la source est re-demandée', () async {
      a.answer = () => const [];
      b.answer = () => [_hit('SourceB')];
      await search();
      health.forgetTrack(lyricsHealthTrackKey('Titre', 'Artiste'));
      await search();
      expect(a.calls, 2);
    });
  });

  group('bypass (searchOne)', () {
    test('une source mise de côté est réinterrogée', () async {
      a.failure = const LyricsSourceException('SourceA', 'en panne');
      b.answer = () => [_hit('SourceB')];
      await search();
      await search();
      await search();
      expect(health.isSetAside('SourceA'), isTrue);
      a.failure = null;
      a.answer = () => [_hit('SourceA')];
      final found = await repository.searchOne(
        sourceName: 'SourceA',
        title: 'Titre',
        artist: 'Artiste',
      );
      expect(found, hasLength(1));
      expect(a.calls, 4);
      // Le succès manuel lève la mise de côté : la recherche suivante
      // l'interroge de nouveau.
      expect(health.isSetAside('SourceA'), isFalse);
      await search();
      expect(a.calls, 5);
    });

    test('un échec manuel compte vers les 3', () async {
      a.failure = const LyricsSourceException('SourceA', 'en panne');
      b.answer = () => [_hit('SourceB')];
      await search();
      await search();
      await expectLater(
        repository.searchOne(
          sourceName: 'SourceA',
          title: 'Titre',
          artist: 'Artiste',
        ),
        throwsA(isA<LyricsSourceException>()),
      );
      expect(health.isSetAside('SourceA'), isTrue);
    });

    test('source inconnue : erreur', () async {
      await expectLater(
        repository.searchOne(
          sourceName: 'Inconnue',
          title: 'Titre',
          artist: 'Artiste',
        ),
        throwsA(isA<LyricsSourceException>()),
      );
    });
  });

  test('aucune source : liste vide, pas d’erreur', () async {
    final empty = LyricsRepository(sources: const [], health: health);
    expect(await empty.searchAll(title: 'Titre', artist: 'Artiste'), isEmpty);
  });

  test('sourceNames liste les sources', () {
    expect(repository.sourceNames, ['SourceA', 'SourceB']);
  });
}
