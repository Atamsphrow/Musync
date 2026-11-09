// Hash de détection de changement des paroles (H93/L118/L119) :
// FNV-1a 64 bits, synchro + non-synchro.
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';

void main() {
  group('lyricsContentHash', () {
    final synced = SyncedLyrics([
      const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
      const LyricLine(timestamp: Duration(seconds: 2), text: 'Deux'),
    ]);
    const unsynced = UnsyncedLyrics('Une\nDeux');

    test('déterministe pour la même entrée', () {
      expect(
        lyricsContentHash(synced, unsynced),
        lyricsContentHash(synced, unsynced),
      );
    });

    test(
      'un changement du seul texte non synchronisé change le hash (L118)',
      () {
        expect(
          lyricsContentHash(synced, unsynced),
          isNot(lyricsContentHash(synced, const UnsyncedLyrics('Une\nTrois'))),
        );
      },
    );

    test('un changement de timestamp change le hash', () {
      final moved = SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
        const LyricLine(timestamp: Duration(seconds: 3), text: 'Deux'),
      ]);
      expect(
        lyricsContentHash(synced, unsynced),
        isNot(lyricsContentHash(moved, unsynced)),
      );
    });

    test('le texte seul sans synchro compte aussi', () {
      expect(
        lyricsContentHash(null, unsynced),
        isNot(lyricsContentHash(null, const UnsyncedLyrics('Autre'))),
      );
    });

    test('vide et absent ne se confondent pas avec du contenu', () {
      expect(
        lyricsContentHash(null, null),
        isNot(lyricsContentHash(synced, unsynced)),
      );
      expect(
        lyricsContentHash(null, null),
        isNot(lyricsContentHash(null, unsynced)),
      );
    });
  });
}
