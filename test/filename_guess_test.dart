// Guessing an artist and a title out of a file name.
//
// The cases below are real names from a library built out of downloads — that
// is the whole reason this exists, and inventing tidier examples would test
// something easier than the problem.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';

void main() {
  void expectGuess(String fileName, {String? artist, String? title}) {
    final guess = FilenameParser.parse(fileName);
    if (artist != null) expect(guess.artist, artist, reason: fileName);
    if (title != null) expect(guess.title, title, reason: fileName);
  }

  group('the ordinary shape', () {
    test('artist - title', () {
      expectGuess('ALG - Biloo.mp3', artist: 'ALG', title: 'Biloo');
    });

    test('underscores stand in for spaces, and _-_ for the separator', () {
      expectGuess(
        'Desiigner_-_Panda_(Lyrics)(360p).mp3',
        artist: 'Desiigner',
        title: 'Panda',
      );
    });

    test('only the last path segment is read', () {
      expectGuess(
        '/storage/0000-0000/audio/ALG - Biloo.mp3',
        artist: 'ALG',
        title: 'Biloo',
      );
    });
  });

  group('decoration a downloader left behind', () {
    test('leading dashes and a trailing "- YouTube"', () {
      expectGuess(
        '- - - BASTA & MAD MAX - ROMBOTRO ( ANATI Remix 2018 ) - YouTube.mp3',
        artist: 'BASTA & MAD MAX',
        // A remix is part of what the track is called, so the group stays.
        title: 'ROMBOTRO ( ANATI Remix 2018 )',
      );
    });

    test('(Official Vidéo) goes, and so does the -mc suffix', () {
      expectGuess(
        '---Mr SAYDA  -  MBA MARINA ANIE (Official Vidéo 2017)-mc.mp3',
        artist: 'Mr SAYDA',
        title: 'MBA MARINA ANIE',
      );
    });

    test('a resolution or a bitrate is never part of a title', () {
      expectGuess('Amaray - Ratsilahy ✅(MP3_160K).mp3', title: 'Ratsilahy');
      expectGuess('X - Y (360P).mp3', title: 'Y');
    });

    test('unbracketed trailing junk goes too', () {
      // `-Nouveauté 2019-` never made it into brackets, so removing the groups
      // could not reach it.
      expectGuess(
        '--Nael feat- Dj Mijay - BETINA -Nouveauté 2019-.mp3',
        artist: 'Nael feat- Dj Mijay',
        title: 'BETINA',
      );
    });

    test('a leading track number is dropped', () {
      expectGuess('03_Titre - Artiste.mp3', artist: 'Titre');
      expectGuess('12. Artiste - Titre.mp3', artist: 'Artiste', title: 'Titre');
    });

    test('-u0026 is an ampersand a downloader mangled', () {
      expectGuess(
        "---Maître GIMS - Corazon ft. Lil Wayne -u0026 French Montana "
        "(Clip Officiel) - YouTube.mp3",
        artist: 'Maître GIMS',
        title: 'Corazon ft. Lil Wayne & French Montana',
      );
    });
  });

  group('what it declines to invent', () {
    test('a name with no separator is a title, and no artist', () {
      // Better an empty field than a confident wrong answer: the user is
      // looking at both of them anyway.
      expectGuess('(Matsubara RN 13).mp3', artist: '');
    });

    test('a leading bracketed group reads as the artist', () {
      expectGuess(
        "(DRAGIN D' Ihosy )  JANGOBO.mp3",
        artist: "DRAGIN D' Ihosy",
        title: 'JANGOBO',
      );
    });

    test('the split is the first spaced dash, not any dash', () {
      // `Nael feat- Dj Mijay` carries a dash inside the artist; splitting there
      // would hand back half a name.
      expectGuess(
        '--Nael feat- Dj Mijay - BETINA.mp3',
        artist: 'Nael feat- Dj Mijay',
        title: 'BETINA',
      );
    });

    test('an empty or extensionless name does not throw', () {
      expect(() => FilenameParser.parse(''), returnsNormally);
      expectGuess('Titre', title: 'Titre');
    });
  });

  group('accents', () {
    test('junk words are matched despite them', () {
      // Dart's \b is defined over [A-Za-z0-9_], so there is no word boundary
      // beside an é — `\bnouveauté\b` can never match, and the detection has
      // to split on letters instead.
      expectGuess('A - B -Nouveauté 2019.mp3', title: 'B');
      expectGuess('A - B (Vidéo Officielle).mp3', title: 'B');
    });

    test('accents in a real name survive untouched', () {
      expectGuess('Maître GIMS - Été.mp3', artist: 'Maître GIMS', title: 'Été');
    });
  });
}
