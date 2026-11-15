import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/search_variants.dart';

void main() {
  group('cleanSearchTitle', () {
    test('retire Live (…)', () {
      expect(
        cleanSearchTitle('Hello (Live at the Royal Albert Hall)'),
        'Hello',
      );
      expect(cleanSearchTitle('Hello (Live)'), 'Hello');
    });

    test('retire feat. avec ou sans parenthèses', () {
      expect(cleanSearchTitle('Get Lucky feat. Pharrell Williams'), 'Get Lucky');
      expect(cleanSearchTitle('Get Lucky ft. Pharrell Williams'), 'Get Lucky');
      expect(
        cleanSearchTitle('Get Lucky (feat. Pharrell Williams)'),
        'Get Lucky',
      );
      expect(cleanSearchTitle('Get Lucky [ft. Pharrell]'), 'Get Lucky');
    });

    test('retire Remix, Remastered, versions', () {
      expect(cleanSearchTitle('Blinding Lights (Remix)'), 'Blinding Lights');
      expect(cleanSearchTitle('Song (ANATI Remix 2018)'), 'Song');
      expect(cleanSearchTitle('Song (2011 Remaster)'), 'Song');
      expect(cleanSearchTitle('Song (Radio Edit)'), 'Song');
      expect(cleanSearchTitle('Song (Acoustic)'), 'Song');
      expect(
        cleanSearchTitle('Satisfaction (Original Single Mono Version)'),
        'Satisfaction',
      );
    });

    test('retire les mentions de téléchargement', () {
      expect(cleanSearchTitle('Song (Official Video 2017)'), 'Song');
      expect(cleanSearchTitle('Song [1080p]'), 'Song');
      expect(cleanSearchTitle('Song (Lyrics) #music'), 'Song');
    });

    test('garde la parenthèse qui fait partie du vrai titre', () {
      expect(
        cleanSearchTitle("(I Can't Get No) Satisfaction"),
        "(I Can't Get No) Satisfaction",
      );
      expect(cleanSearchTitle('Live Forever'), 'Live Forever');
      expect(cleanSearchTitle('Live Forever (Live)'), 'Live Forever');
      expect(cleanSearchTitle('Video Games'), 'Video Games');
      expect(cleanSearchTitle('Left Behind'), 'Left Behind');
      expect(cleanSearchTitle('Stay (with Me)'), 'Stay (with Me)');
      expect(cleanSearchTitle('Song (1999)'), 'Song (1999)');
      expect(cleanSearchTitle('Song ((Live))'), 'Song');
    });

    test('ne rend jamais une chaîne vide', () {
      expect(cleanSearchTitle('(Live)'), '(Live)');
      expect(cleanSearchTitle(''), '');
    });
  });

  group('cleanSearchArtist', () {
    test('retire l\'invité, garde un duo réel', () {
      expect(
        cleanSearchArtist('Daft Punk feat. Pharrell Williams'),
        'Daft Punk',
      );
      expect(cleanSearchArtist('Simon & Garfunkel'), 'Simon & Garfunkel');
    });
  });

  group('buildSearchVariants', () {
    test('complet, nettoyé, titre seul, dans cet ordre', () {
      final v = buildSearchVariants(
        usedTitle: 'Hello (Live at the Royal Albert Hall)',
        usedArtist: 'Unknown',
        guessTitle: 'Hello (Live at the Royal Albert Hall)',
        guessArtist: 'Adele',
      );
      expect(v, [
        (title: 'Hello (Live at the Royal Albert Hall)', artist: 'Adele'),
        (title: 'Hello', artist: 'Adele'),
        (title: 'Hello', artist: ''),
      ]);
    });

    test('deviné identique : il ne reste que le titre seul', () {
      expect(
        buildSearchVariants(
          usedTitle: 'Hello',
          usedArtist: 'Adele',
          guessTitle: 'Hello',
          guessArtist: 'Adele',
        ),
        [(title: 'Hello', artist: '')],
      );
    });

    test('un deviné vide retombe sur la requête utilisée', () {
      expect(
        buildSearchVariants(
          usedTitle: 'T',
          usedArtist: 'A',
          guessTitle: '',
          guessArtist: '',
        ),
        [(title: 'T', artist: '')],
      );
    });

    test('comparaison insensible à la casse et aux espaces', () {
      final v = buildSearchVariants(
        usedTitle: 'hello',
        usedArtist: 'adele',
        guessTitle: 'Hello ',
        guessArtist: ' Adele',
      );
      expect(v, [(title: 'Hello', artist: '')]);
    });

    test('la variante nettoyée déjà utilisée est sautée', () {
      final v = buildSearchVariants(
        usedTitle: 'Hello',
        usedArtist: 'Adele',
        guessTitle: 'Hello (Live)',
        guessArtist: 'Adele',
      );
      expect(v, [
        (title: 'Hello (Live)', artist: 'Adele'),
        (title: 'Hello', artist: ''),
      ]);
    });

    test('artiste deviné vide : retombe sur l\'artiste utilisé', () {
      final v = buildSearchVariants(
        usedTitle: 'X',
        usedArtist: 'Y',
        guessTitle: 'Song (Remix)',
        guessArtist: '',
      );
      expect(v, [
        (title: 'Song (Remix)', artist: 'Y'),
        (title: 'Song', artist: 'Y'),
        (title: 'Song', artist: ''),
      ]);
    });

    test('jamais deux fois la même requête', () {
      final v = buildSearchVariants(
        usedTitle: 'A',
        usedArtist: 'B',
        guessTitle: 'Song (Live) feat. Z',
        guessArtist: 'Art feat. W',
      );
      final keys = v.map((e) => '${e.title}|${e.artist}').toSet();
      expect(keys.length, v.length);
    });
  });
}
