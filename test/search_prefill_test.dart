// What the lyrics search fields start from: the tags, unless a tag is not
// really a name — then the file name's guess, or the tag cleaned.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/music_scanner.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/search_prefill.dart';

void main() {
  group('prefillTitle', () {
    String title(String tag, String path) => prefillTitle(
          tag,
          filePath: path,
          guess: FilenameParser.parse(path),
        );

    test('a real title stays, even when the file name says more', () {
      // The guess would be `Bohemian Rhapsody (Remastered 2011)`, which the
      // exact sources do not find.
      expect(
        title('Bohemian Rhapsody',
            '/m/Queen - Bohemian Rhapsody (Remastered 2011).mp3'),
        'Bohemian Rhapsody',
      );
      expect(title('7 Rings', '/m/07 - 7 Rings.mp3'), '7 Rings');
    });

    test('a placeholder or the bare file name gives way to the guess', () {
      expect(title('<unknown>', '/m/ALG - Biloo.mp3'), 'Biloo');
      expect(title('Track 03', '/m/ALG - Biloo.mp3'), 'Biloo');
      expect(
        title('ALG - Biloo (Official Video)', '/m/ALG - Biloo (Official Video).mp3'),
        'Biloo',
      );
    });

    test('artist and title folded into the tag give way to the guess', () {
      expect(
        title('Rick Astley - Never Gonna Give You Up',
            '/m/Rick Astley - Never Gonna Give You Up.mp3'),
        'Never Gonna Give You Up',
      );
    });

    test('a decorated tag is cleaned, not swapped for an unrelated guess', () {
      expect(title('Panda (Lyrics)', '/m/track12.mp3'), 'Panda');
      expect(title('Never_Gonna_Give_You_Up', '/m/x.mp3'),
          'Never Gonna Give You Up');
    });

    test('a version in the title is part of it', () {
      expect(
        title('Bohemian Rhapsody - Remastered 2011', '/m/x.mp3'),
        'Bohemian Rhapsody - Remastered 2011',
      );
    });
  });

  group('prefillArtist', () {
    String artist(String tag, String path) =>
        prefillArtist(tag, guess: FilenameParser.parse(path));

    test('a real name stays', () {
      expect(artist('Queen', '/m/Freddie - Bohemian Rhapsody.mp3'), 'Queen');
      expect(artist('Simon & Garfunkel', '/m/x.mp3'), 'Simon & Garfunkel');
    });

    test('unknown, Various Artists and channels give way to the guess', () {
      expect(artist(MusicScanner.unknownArtist, '/m/ALG - Biloo.mp3'), 'ALG');
      expect(artist('Various Artists', '/m/ALG - Biloo.mp3'), 'ALG');
      expect(artist('RickAstleyVEVO', '/m/Rick Astley - Up.mp3'),
          'Rick Astley');
      expect(artist('Daft Punk - Topic', '/m/x.mp3'), 'Daft Punk');
    });

    test('a channel with nothing better is stripped of its suffix', () {
      expect(artist('RickAstleyVEVO', '/m/Never Gonna Give You Up.mp3'),
          'Rick Astley');
    });

    test('nothing better than a placeholder: the tag stays', () {
      expect(artist('<unknown>', '/m/Biloo.mp3'), '<unknown>');
    });
  });

  group('aiFilenameHints', () {
    test('the folder and the real tags, placeholders left out', () {
      final hints = aiFilenameHints(
        filePath: '/storage/emulated/0/Music/Daft Punk - Discovery/01.mp3',
        title: 'One More Time',
        artist: '<unknown>',
        album: 'Discovery',
      );
      expect(hints, contains('dossier : Daft Punk - Discovery'));
      expect(hints, contains('titre « One More Time »'));
      expect(hints, contains('album « Discovery »'));
      expect(hints, isNot(contains('unknown')));
    });

    test('a download folder and no tags: nothing to say', () {
      expect(
        aiFilenameHints(
          filePath: '/storage/emulated/0/Download/x.mp3',
          title: '',
          artist: MusicScanner.unknownArtist,
          album: MusicScanner.unknownAlbum,
        ),
        isNull,
      );
      expect(
        aiFilenameHints(
          filePath: '/storage/0000-0000/x.mp3',
          title: '<unknown>',
          artist: '',
          album: '',
        ),
        isNull,
      );
    });
  });
}
