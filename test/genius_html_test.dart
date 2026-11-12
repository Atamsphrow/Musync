// Tests de l'extraction Genius (page HTML) et de l'appariement du
// morceau. Le HTML est une page miniature, pas une page réelle —
// l'extraction ne dépend que des conteneurs, des en-têtes et des
// `<br>`, pas du reste de la page.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/providers/genius_html.dart';

const _page = '''
<html><body>
<div data-lyrics-container="true">
<div data-exclude-from-selection="true">12 Contributors</div>
[Refrain]<br>Yeah, I&#39;m in the city<br>
You don&#39;t even have to do too much
</div>
<div data-lyrics-container="true">
<span>Turn me on with just a <a href="/x">touch</a></span><br>
And baby, you can <b>go</b> &amp; stay
</div>
<div data-lyrics-container="false">Not lyrics</div>
</body></html>
''';

void main() {
  group('extractGeniusLyrics', () {
    test('conteneurs joints, en-tête retiré, <br> et entités', () {
      expect(
        extractGeniusLyrics(_page),
        '[Refrain]\n'
        "Yeah, I'm in the city\n"
        "You don't even have to do too much\n"
        'Turn me on with just a touch\n'
        'And baby, you can go & stay',
      );
    });

    test('marqueur de section gardé (convention Musync)', () {
      expect(
        extractGeniusLyrics(_page)!.split('\n').first,
        '[Refrain]',
      );
    });

    test('aucun conteneur : null', () {
      expect(extractGeniusLyrics('<html><body>rien</body></html>'), isNull);
    });

    test('conteneur vide : null', () {
      expect(
        extractGeniusLyrics(
          '<div data-lyrics-container="true"></div>',
        ),
        isNull,
      );
    });

    test('divs imbriqués équilibrés', () {
      expect(
        extractGeniusLyrics(
          '<div data-lyrics-container="true">'
          '<div><span>Un</span><div>Deux</div></div><br>Trois'
          '</div>',
        ),
        'UnDeux\nTrois',
      );
    });

    test('références numériques décodées', () {
      expect(
        extractGeniusLyrics(
          '<div data-lyrics-container="true">'
          'Caf&#233; &#x27;rouge&#x27;</div>',
        ),
        "Café 'rouge'",
      );
    });
  });

  group('geniusMatch', () {
    test('titre et artiste exacts', () {
      expect(
        geniusMatch(
          candidateTitle: 'Blinding Lights',
          candidateArtists: 'The Weeknd',
          primaryArtist: 'The Weeknd',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
        ),
        isTrue,
      );
    });

    test('parenthèses écartées des deux côtés', () {
      expect(
        geniusMatch(
          candidateTitle: 'Blinding Lights (Remix)',
          candidateArtists: 'The Weeknd & ROSALÍA',
          primaryArtist: 'The Weeknd',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
        ),
        isTrue,
      );
    });

    test('artiste secondaire accepté', () {
      expect(
        geniusMatch(
          candidateTitle: 'Blinding Lights (Remix)',
          candidateArtists: 'The Weeknd & ROSALÍA',
          primaryArtist: 'The Weeknd',
          title: 'Blinding Lights',
          artist: 'ROSALÍA',
        ),
        isTrue,
      );
    });

    test('titre préfixe refusé : Hello Again n’est pas Hello', () {
      expect(
        geniusMatch(
          candidateTitle: 'Hello Again',
          candidateArtists: 'Adele',
          primaryArtist: 'Adele',
          title: 'Hello',
          artist: 'Adele',
        ),
        isFalse,
      );
    });

    test('autre artiste refusé', () {
      expect(
        geniusMatch(
          candidateTitle: 'Blinding Lights',
          candidateArtists: 'The Weeknd',
          primaryArtist: 'The Weeknd',
          title: 'Blinding Lights',
          artist: 'Dua Lipa',
        ),
        isFalse,
      );
    });

    test('traduction refusée : le titre traduit n’est pas le titre', () {
      expect(
        geniusMatch(
          candidateTitle: 'Blinding Lights (Traduction Française)',
          candidateArtists: 'Genius Traductions Françaises',
          primaryArtist: 'Genius Traductions Françaises',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
        ),
        isFalse,
      );
    });
  });

  group('geniusQuery', () {
    test('titre nettoyé, premier artiste seulement', () {
      expect(
        geniusQuery(
          title: 'Blinding Lights - Remastered 2011',
          artist: 'The Weeknd, ROSALÍA',
        ),
        'Blinding Lights The Weeknd',
      );
    });
  });
}
