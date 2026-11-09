// Tests du résolveur d'identité (DESIGN.md §4, FILES.md §4.3).
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/data/lyrics_query_resolver.dart';

Song _song({
  String title = 'Titre',
  String artist = 'Artiste',
  String album = '',
  int duration = 180000,
  String filePath = '/musique/Artiste - Titre.mp3',
}) => Song(
  id: 1,
  title: title,
  artist: artist,
  album: album,
  duration: duration,
  filePath: filePath,
);

void main() {
  test('placeholders retirés de la requête', () async {
    final resolver = LyricsQueryResolver(
      parseFilename: (_) => (artist: 'Artiste Deviné', title: ''),
    );
    final resolved = await resolver.resolve(
      _song(title: 'Vrai Titre', artist: 'Artiste inconnu'),
    );
    expect(resolved.queries, hasLength(1));
    expect(resolved.primary.title, 'Vrai Titre');
    // « Artiste inconnu » n'est jamais envoyé : l'artiste vient du nom
    // de fichier.
    expect(resolved.primary.artist, 'Artiste Deviné');
  });

  test('tags vides → heuristique nom de fichier', () async {
    final resolver = LyricsQueryResolver(
      parseFilename: (_) => (artist: 'Artiste Réel', title: 'Vrai Titre'),
    );
    final resolved = await resolver.resolve(
      _song(
        title: '',
        artist: '',
        album: 'Album inconnu',
        filePath: '/musique/Artiste Réel - Vrai Titre.mp3',
      ),
    );
    expect(resolved.queries, hasLength(1));
    expect(resolved.primary.title, 'Vrai Titre');
    expect(resolved.primary.artist, 'Artiste Réel');
    expect(resolved.primary.origin, LyricsQueryOrigin.filename);
  });

  test('tags ≠ nom de fichier → deux requêtes, pas une', () async {
    var aiCalls = 0;
    final resolver = LyricsQueryResolver(
      parseFilename: (_) => (artist: 'Artiste Réel', title: 'Vrai Titre'),
      readWithAi: (_) async {
        aiCalls++;
        return null;
      },
    );
    final resolved = await resolver.resolve(
      _song(title: '09', artist: 'Artiste inconnu'),
    );
    // Tags nettoyés : titre « 09 », artiste vide → l'heuristique comble
    // l'artiste, mais la devinette contredit le titre « 09 » : deux
    // requêtes, la seconde portant le vrai titre.
    expect(resolved.queries, hasLength(2));
    expect(resolved.primary.title, '09');
    expect(resolved.primary.artist, 'Artiste Réel');
    expect(resolved.queries[1].title, 'Vrai Titre');
    expect(aiCalls, 1); // désaccord : le LLM arbitre.

    // …mais des tags COMPLETS qui contredisent le nom de fichier
    // donnent bien deux requêtes.
    final resolved2 = await resolver.resolve(
      _song(title: 'Mauvais Titre', artist: 'Mauvais Artiste'),
    );
    expect(resolved2.queries, hasLength(2));
    expect(resolved2.primary.title, 'Mauvais Titre');
    expect(resolved2.queries[1].title, 'Vrai Titre');
    expect(resolved2.queries[1].artist, 'Artiste Réel');
  });

  test('même requête deux fois → une seule', () async {
    final resolver = LyricsQueryResolver(
      parseFilename: (_) => (artist: 'Artiste', title: 'Titre'),
    );
    final resolved = await resolver.resolve(_song());
    expect(resolved.queries, hasLength(1));
  });

  test('LLM appelé seulement si heuristique insuffisante', () async {
    var aiCalls = 0;
    final resolver = LyricsQueryResolver(
      parseFilename: (_) => (artist: '', title: 'Titre'),
      readWithAi: (_) async {
        aiCalls++;
        return (artist: 'Artiste Deviné', title: 'Titre');
      },
    );
    final resolved = await resolver.resolve(
      _song(title: '', artist: ''),
    );
    expect(aiCalls, 1);
    expect(resolved.primary.artist, 'Artiste Deviné');
    expect(resolved.primary.title, 'Titre');
  });

  test('LLM non appelé quand tags complets et nom de fichier d\'accord', () async {
    var aiCalls = 0;
    final resolver = LyricsQueryResolver(
      parseFilename: (_) => (artist: 'Artiste', title: 'Titre'),
      readWithAi: (_) async {
        aiCalls++;
        return null;
      },
    );
    await resolver.resolve(_song());
    expect(aiCalls, 0);
  });

  test('LLM non appelé quand aiFallback est faux', () async {
    var aiCalls = 0;
    final resolver = LyricsQueryResolver(
      parseFilename: (_) => (artist: '', title: ''),
      readWithAi: (_) async {
        aiCalls++;
        return (artist: 'Artiste', title: 'Titre');
      },
    );
    final resolved = await resolver.resolve(
      _song(title: '', artist: ''),
      aiFallback: false,
    );
    expect(aiCalls, 0);
    expect(resolved.queries, isEmpty);
  });

  test('rien d\'exploitable nulle part → aucune requête', () async {
    final resolver = LyricsQueryResolver(
      parseFilename: (_) => (artist: '', title: ''),
      readWithAi: (_) async => null,
    );
    final resolved = await resolver.resolve(
      _song(title: '', artist: ''),
    );
    expect(resolved.queries, isEmpty);
    expect(resolved.goodQuality, isFalse);
  });

  test('goodQuality : faux sur placeholder ou titre vide', () async {
    final resolver = LyricsQueryResolver(
      parseFilename: (_) => (artist: '', title: ''),
    );
    final good = await resolver.resolve(_song());
    expect(good.goodQuality, isTrue);
    final placeholder = await resolver.resolve(
      _song(title: 'Track 01', artist: 'Artiste'),
    );
    expect(placeholder.goodQuality, isFalse);
  });
}
