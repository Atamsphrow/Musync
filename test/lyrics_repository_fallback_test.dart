// Tests des deux passes de searchAll : les sources de repli (Genius)
// ne sont interrogées que quand la première passe n'a ramené aucune
// parole synchronisée.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

class _FakeSource extends LyricsSource {
  _FakeSource(this._name, {this.fallback = false});

  final String _name;
  final bool fallback;

  @override
  String get name => _name;

  @override
  bool get isFallback => fallback;

  int calls = 0;
  List<LyricsSearchResult> Function()? answer;

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    calls++;
    return answer?.call() ?? const [];
  }
}

LyricsSearchResult _syncedHit(String source) => LyricsSearchResult(
  source: source,
  title: 'Titre',
  artist: 'Artiste',
  syncedLyrics: SyncedLyrics([
    const LyricLine(timestamp: Duration(seconds: 1), text: 'Paroles'),
  ]),
  unsyncedLyrics: null,
  confidence: 0.9,
);

LyricsSearchResult _plainHit(String source) => LyricsSearchResult(
  source: source,
  title: 'Titre',
  artist: 'Artiste',
  syncedLyrics: null,
  unsyncedLyrics: const UnsyncedLyrics('Paroles'),
  confidence: 0.65,
);

void main() {
  late _FakeSource primary;
  late _FakeSource genius;
  late LyricsRepository repository;

  setUp(() {
    primary = _FakeSource('Primaire');
    genius = _FakeSource('Genius', fallback: true);
    repository = LyricsRepository(sources: [primary, genius]);
  });

  Future<List<LyricsSearchResult>> search() =>
      repository.searchAll(title: 'Titre', artist: 'Artiste');

  test('synchro trouvée : le repli n’est pas interrogé', () async {
    primary.answer = () => [_syncedHit('Primaire')];

    final results = await search();

    expect(results, hasLength(1));
    expect(results.single.source, 'Primaire');
    expect(genius.calls, 0);
  });

  test('seulement du texte simple : le repli est interrogé', () async {
    primary.answer = () => [_plainHit('Primaire')];
    genius.answer = () => [_plainHit('Genius')];

    final results = await search();

    expect(results, hasLength(2));
    expect(results.map((r) => r.source), ['Primaire', 'Genius']);
    expect(genius.calls, 1);
  });

  test('rien du tout : le repli est interrogé', () async {
    genius.answer = () => [_plainHit('Genius')];

    final results = await search();

    expect(results, hasLength(1));
    expect(results.single.source, 'Genius');
    expect(genius.calls, 1);
  });

  test('repli sans rien : liste vide, pas d’erreur', () async {
    final results = await search();

    expect(results, isEmpty);
    expect(genius.calls, 1);
  });

  test('le repli seul n’est pas une source normale', () {
    expect(primary.isFallback, isFalse);
    expect(genius.isFallback, isTrue);
  });
}
