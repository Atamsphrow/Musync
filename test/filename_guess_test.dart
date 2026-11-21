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

  group('what converters and yt-dlp leave behind', () {
    test('a YouTube id, bracketed or appended, is not part of the title', () {
      expectGuess(
        'Rick Astley - Never Gonna Give You Up [dQw4w9WgXcQ].mp3',
        artist: 'Rick Astley',
        title: 'Never Gonna Give You Up',
      );
      expectGuess(
        'Rick Astley - Never Gonna Give You Up-dQw4w9WgXcQ.mp3',
        title: 'Never Gonna Give You Up',
      );
      // An id may hold underscores: they are not spaces.
      expectGuess('A - B [a_B3c-dE4fG].mp3', title: 'B');
    });

    test('an eleven-letter word in brackets is not an id', () {
      expectGuess('A - B [Instrumenta].mp3', title: 'B [Instrumenta]');
    });

    test('the converter site goes, before or after', () {
      expectGuess(
        'y2mate.com - Rick Astley - Never Gonna Give You Up_v720P.mp3',
        artist: 'Rick Astley',
        title: 'Never Gonna Give You Up',
      );
      expectGuess('[www.mp3juices.cc] Daft Punk - One More Time.mp3',
          artist: 'Daft Punk', title: 'One More Time');
      expectGuess('Daft Punk - One More Time - ytmp3.cc.mp3',
          title: 'One More Time');
      expectGuess('Daft Punk - One More Time (www.site.com).mp3',
          title: 'One More Time');
    });

    test('a bare bitrate or resolution at the end goes', () {
      expectGuess('A - B 320kbps.mp3', title: 'B');
      expectGuess('A - B HD.mp3', title: 'B');
    });

    test('(Audio), (Visualizer), (Official MV) are decoration', () {
      expectGuess('A - B (Audio).mp3', title: 'B');
      expectGuess('A - B (Official Visualizer).mp3', title: 'B');
      expectGuess('A - B [Official MV].mp3', title: 'B');
      expectGuess('A - B (Video Oficial).mp3', title: 'B');
    });
  });

  group('track numbers', () {
    test('a name that starts with a number keeps it', () {
      // The old rule read any number and a space as a track number.
      expectGuess('3 Doors Down - Kryptonite.mp3', artist: '3 Doors Down');
      expectGuess('50 Cent - In Da Club.mp3', artist: '50 Cent');
      expectGuess('7 Rings.mp3', title: '7 Rings');
    });

    test('zero-padded, punctuated, disc-track and "Track 05" are numbers', () {
      expectGuess('01 Titre.mp3', title: 'Titre');
      expectGuess('1-03 Daft Punk - Digital Love.mp3', artist: 'Daft Punk');
      expectGuess('Track 05 - Daft Punk - Aerodynamic.mp3',
          artist: 'Daft Punk', title: 'Aerodynamic');
    });

    test('a number on the title side goes too', () {
      expectGuess('Daft Punk - 03. Digital Love.mp3', title: 'Digital Love');
      expectGuess(
        'Daft Punk - Discovery - 03 - Digital Love.mp3',
        artist: 'Daft Punk',
        title: 'Digital Love',
      );
      // A title that is a number stays one.
      expectGuess('Taylor Swift - 22.mp3', title: '22');
    });
  });

  group('other separators', () {
    test('an en dash needs no spaces, a hyphen does', () {
      expectGuess('Daft Punk–One More Time.mp3',
          artist: 'Daft Punk', title: 'One More Time');
      expectGuess('Jay-Z.mp3', artist: '', title: 'Jay-Z');
    });

    test('a quoted title after the artist', () {
      expectGuess('Rick Astley "Never Gonna Give You Up" (Official Video).mp3',
          artist: 'Rick Astley', title: 'Never Gonna Give You Up');
      expectGuess('Stromae « Papaoutai » (Live).mp3',
          artist: 'Stromae', title: 'Papaoutai (Live)');
    });

    test('quotes wrapping a half are dropped', () {
      expectGuess('Rick Astley - "Never Gonna Give You Up".mp3',
          title: 'Never Gonna Give You Up');
      // An apostrophe is not a quote.
      expectGuess("Lynyrd Skynyrd - Don't Ask Me No Questions.mp3",
          title: "Don't Ask Me No Questions");
    });
  });

  group('completeGuess', () {
    test('a field the model left empty comes from the heuristic', () {
      expect(
        completeGuess(
          (artist: '', title: 'Biloo'),
          (artist: 'ALG', title: 'Biloo'),
        ),
        (artist: 'ALG', title: 'Biloo'),
      );
      // The model answered nothing at all: the heuristic stands.
      expect(
        completeGuess((artist: '', title: ''), (artist: 'A', title: 'B')),
        (artist: 'A', title: 'B'),
      );
    });

    test('the model has the last word on what it filled', () {
      expect(
        completeGuess(
          (artist: 'Rick Astley', title: 'Never Gonna Give You Up'),
          (artist: '', title: 'never gonna give you up official'),
        ),
        (artist: 'Rick Astley', title: 'Never Gonna Give You Up'),
      );
    });

    test('never the same name in both fields', () {
      // The model read `Biloo - ALG` the other way round and left the
      // title empty: the heuristic's title is the model's artist.
      expect(
        completeGuess(
          (artist: 'Biloo', title: ''),
          (artist: 'ALG', title: 'Biloo'),
        ),
        (artist: 'Biloo', title: ''),
      );
    });
  });

  test('stripDecoration leaves a clean tag alone', () {
    expect(FilenameParser.stripDecoration('Bohemian Rhapsody (Remastered 2011)'),
        'Bohemian Rhapsody (Remastered 2011)');
    expect(FilenameParser.stripDecoration('Panda (Lyrics)'), 'Panda');
    expect(FilenameParser.stripDecoration('Never_Gonna_Give_You_Up'),
        'Never Gonna Give You Up');
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
