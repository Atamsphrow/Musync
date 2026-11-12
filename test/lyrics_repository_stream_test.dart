// Tests de searchAllStream : les résultats arrivent au fur et à mesure
// que les sources répondent, la dernière émission vaut searchAll.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

class _DelayedSource extends LyricsSource {
  _DelayedSource(this._name, {this.fallback = false});

  final String _name;
  final bool fallback;

  @override
  String get name => _name;

  @override
  bool get isFallback => fallback;

  int calls = 0;
  Duration delay = Duration.zero;
  List<LyricsSearchResult> Function()? answer;
  Object? throwError;

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
    FilenameGuess? filenameGuess,
  }) async {
    calls++;
    await Future<void>.delayed(delay);
    if (throwError != null) throw throwError!;
    return answer?.call() ?? const [];
  }
}

LyricsSearchResult _hit(
  String source,
  double confidence, {
  bool synced = true,
}) => LyricsSearchResult(
  source: source,
  title: 'Titre',
  artist: 'Artiste',
  syncedLyrics: synced
      ? SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'Paroles'),
        ])
      : null,
  unsyncedLyrics: synced ? null : const UnsyncedLyrics('Paroles'),
  confidence: confidence,
);

void main() {
  test('la première source répond d’abord, la liste se classe à la fin',
      () async {
    final fast = _DelayedSource('Rapide')
      ..delay = const Duration(milliseconds: 10)
      ..answer = () => [_hit('Rapide', 0.85)];
    final slow = _DelayedSource('Lente')
      ..delay = const Duration(milliseconds: 80)
      ..answer = () => [_hit('Lente', 0.90)];
    final repository = LyricsRepository(sources: [fast, slow]);

    final emissions = await repository
        .searchAllStream(title: 'Titre', artist: 'Artiste')
        .toList();

    expect(emissions.length, 2);
    // D'abord la rapide seule…
    expect(emissions[0].map((r) => r.source), ['Rapide']);
    // …puis les deux, classées par confiance.
    expect(emissions[1].map((r) => r.source), ['Lente', 'Rapide']);
    // La dernière émission vaut searchAll (mêmes sources, mêmes
    // confiances — les instances diffèrent, la fausse source en crée
    // de neuves à chaque appel).
    final again = await repository.searchAll(
      title: 'Titre',
      artist: 'Artiste',
    );
    expect(
      again.map((r) => '${r.source}:${r.confidence}'),
      emissions[1].map((r) => '${r.source}:${r.confidence}'),
    );
  });

  test('repli : le texte seul sort d’abord, le calé le devance ensuite',
      () async {
    final primary = _DelayedSource('Primaire')
      ..answer = () => [_hit('Primaire', 0.65, synced: false)];
    final genius = _DelayedSource('Genius', fallback: true)
      ..delay = const Duration(milliseconds: 50)
      ..answer = () => [_hit('Genius', 0.80)];
    final repository = LyricsRepository(sources: [primary, genius]);

    final emissions = await repository
        .searchAllStream(title: 'Titre', artist: 'Artiste')
        .toList();

    expect(emissions.length, 2);
    expect(emissions[0].map((r) => r.source), ['Primaire']);
    expect(emissions[1].map((r) => r.source), ['Genius', 'Primaire']);
    expect(genius.calls, 1);
  });

  test('toutes les sources en échec : le flux se termine en erreur',
      () async {
    final failing = _DelayedSource('Cassée')
      ..throwError = const LyricsSourceException('Cassée', 'En panne.');
    final repository = LyricsRepository(sources: [failing]);

    await expectLater(
      repository.searchAllStream(title: 'Titre', artist: 'Artiste'),
      emitsError(isA<LyricsSourceException>()),
    );
  });
}
