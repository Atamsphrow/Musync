// Tests for what V2 added around the library: the lyrics-status scanner behind
// the catalogue's three tabs, the user's list of lyrics sources, and the debug
// log the Settings screen shows.
//
// These are the pieces with real logic and no widget tree, so they are asserted
// directly. The scanner's disk cache is exercised through its public surface
// only — `path_provider` has no plugin in a unit test, and the point of the
// try/catch around persistence is precisely that this must not matter.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/id3_writer.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/lyrics_status.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/catalogue_provider.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:musync/features/settings/data/lyrics_source_config.dart';
import 'package:musync/features/settings/providers/settings_provider.dart';

void main() {
  // path_provider goes through a platform channel, and a channel call without
  // an initialised binding throws before it ever reaches the "no plugin here"
  // answer these tests are written to expect.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LyricsStatusScanner', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('musync_status_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    /// An MP3 stand-in, optionally tagged.
    Future<String> makeTrack(
      String name, {
      SyncedLyrics? synced,
      UnsyncedLyrics? unsynced,
    }) async {
      final file = File('${tempDir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(
        Uint8List.fromList(List<int>.generate(2048, (i) => (i * 11) % 256)),
      );
      if (synced != null || unsynced != null) {
        await Id3Writer.writeLyrics(
          file.path,
          synced: synced,
          unsynced: unsynced,
        );
      }
      return file.path;
    }

    test('sorts a track into each of the three states', () async {
      final none = await makeTrack('none.mp3');
      final plain = await makeTrack(
        'plain.mp3',
        unsynced: const UnsyncedLyrics('Des paroles sans horodatage'),
      );
      final synced = await makeTrack(
        'synced.mp3',
        synced: SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 1), text: 'Une'),
        ]),
      );

      final scanner = LyricsStatusScanner();
      final result = await scanner.statusOfAll([none, plain, synced]);

      expect(result[none], LyricsStatus.none);
      expect(result[plain], LyricsStatus.plain);
      expect(result[synced], LyricsStatus.synced);
    });

    test(
      'a missing file counts as having nothing, and does not throw',
      () async {
        final scanner = LyricsStatusScanner();
        final gone = '${tempDir.path}${Platform.pathSeparator}absent.mp3';

        // One unreadable track must not take down the classification of a whole
        // library, which is scanned in one sweep.
        expect(await scanner.statusOf(gone), LyricsStatus.none);
      },
    );

    test('re-reads a file once its modification time moves', () async {
      final path = await makeTrack('changing.mp3');
      final scanner = LyricsStatusScanner();

      expect(await scanner.statusOf(path), LyricsStatus.none);

      await Id3Writer.writeLyrics(
        path,
        synced: SyncedLyrics([
          const LyricLine(timestamp: Duration(seconds: 2), text: 'Ajoutée'),
        ]),
      );
      // The cache is keyed by mtime, and a write inside the same millisecond
      // would look unchanged — which is exactly why `forget` exists and why
      // embedLyrics calls it. Nudge the clock rather than assert on timing.
      await File(
        path,
      ).setLastModified(DateTime.now().add(const Duration(seconds: 2)));

      expect(await scanner.statusOf(path), LyricsStatus.synced);
    });

    test('forget drops an entry so the next read goes back to disk', () async {
      final path = await makeTrack('forgotten.mp3');
      final scanner = LyricsStatusScanner();
      await scanner.statusOf(path);

      await Id3Writer.writeLyrics(
        path,
        unsynced: const UnsyncedLyrics('Écrites dans la même milliseconde'),
      );
      scanner.forget(path);

      expect(await scanner.statusOf(path), LyricsStatus.plain);
    });

    test('a track whose USLT is LRC lands in the synchronised tab', () async {
      // The T11 path, seen from the catalogue: such a file used to be filed
      // under "paroles simples" even though its timings were right there.
      final path = await makeTrack(
        'lrc.mp3',
        unsynced: const UnsyncedLyrics('[00:01.00]Une\n[00:04.50]Deux'),
      );

      expect(await LyricsStatusScanner().statusOf(path), LyricsStatus.synced);
    });
  });

  group('lyrics source settings', () {
    test('normaliseBaseUrl accepts the forms people actually paste', () {
      // All four are the same instance; only the last is what the client wants.
      expect(normaliseBaseUrl('https://lrclib.net'), 'https://lrclib.net/api');
      expect(normaliseBaseUrl('https://lrclib.net/'), 'https://lrclib.net/api');
      expect(
        normaliseBaseUrl('https://lrclib.net/api'),
        'https://lrclib.net/api',
      );
      expect(
        normaliseBaseUrl('  https://lrclib.net/api/  '),
        'https://lrclib.net/api',
      );
    });

    test('validateBaseUrl catches typing mistakes, not unreachable hosts', () {
      expect(validateBaseUrl('https://example.org'), isNull);
      expect(validateBaseUrl('http://192.168.1.10:3000'), isNull);
      // Reachability is not this function's job — only a real search can say.
      expect(validateBaseUrl('https://nothing-here.invalid'), isNull);

      expect(validateBaseUrl(''), isNotNull);
      expect(validateBaseUrl('lrclib.net'), isNotNull, reason: 'pas de schéma');
      expect(validateBaseUrl('ftp://lrclib.net'), isNotNull);
    });

    group('LyricsSourceStore', () {
      test('an entry survives a save and a reload', () async {
        final store = LyricsSourceStore();
        const custom = LyricsSourceConfig(
          id: 'custom-1',
          name: 'Miroir',
          baseUrl: 'https://miroir.example/api',
          enabled: false,
        );

        try {
          await store.save([lrclibDefault, custom]);
        } on MissingPluginException {
          // No path_provider in a unit test. The round trip below is what
          // matters and is asserted through the model instead.
          final decoded = LyricsSourceConfig.fromJson(
            jsonDecode(jsonEncode(custom.toJson())),
          );
          expect(decoded, custom);
          return;
        }

        expect(await store.load(), contains(custom));
      });

      test('a malformed record is skipped, not fatal', () {
        expect(LyricsSourceConfig.fromJson(null), isNull);
        expect(LyricsSourceConfig.fromJson('pas un objet'), isNull);
        expect(LyricsSourceConfig.fromJson({'id': 'x'}), isNull);
        expect(
          LyricsSourceConfig.fromJson({'id': '', 'name': 'n', 'baseUrl': 'u'}),
          isNull,
        );

        expect(
          LyricsSourceConfig.fromJson({
            'id': 'x',
            'name': 'Nom',
            'baseUrl': 'https://x/api',
          }),
          isNotNull,
        );
      });
    });
  });

  group('DebugLog', () {
    setUp(DebugLog.instance.clear);

    test('keeps newest first for the panel, oldest first in the report', () {
      DebugLog.instance.info('A', 'première');
      DebugLog.instance.error('B', 'seconde');

      expect(DebugLog.instance.entries.map((e) => e.message), [
        'seconde',
        'première',
      ]);

      final report = DebugLog.instance.report();
      expect(
        report.indexOf('première'),
        lessThan(report.indexOf('seconde')),
        reason: 'un rapport se lit dans l\'ordre où les choses se sont passées',
      );
    });

    test('drops the oldest rather than growing without bound', () {
      // This runs for the whole life of the process behind a screen nobody
      // opens, so the bound is the point.
      for (var i = 0; i < 500; i++) {
        DebugLog.instance.info('Boucle', 'entrée $i');
      }

      final entries = DebugLog.instance.entries;
      expect(entries.length, lessThanOrEqualTo(400));
      expect(entries.first.message, 'entrée 499');
    });

    test('an error carries its cause and stack into the report', () {
      DebugLog.instance.error(
        'Id3Writer',
        'Écriture refusée',
        error: const FileSystemException('read-only'),
        stackTrace: StackTrace.current,
      );

      final report = DebugLog.instance.report();
      expect(report, contains('ERROR'));
      expect(report, contains('Id3Writer'));
      expect(report, contains('read-only'));
    });

    test('says so plainly when there is nothing to report', () {
      expect(DebugLog.instance.report(), 'Journal vide.');
    });
  });

  // T26: switching tabs was perceptibly slow because the filter watched the tab
  // and walked all 1876 tracks again on every tap. The grouping now happens once
  // and a tab switch is a map lookup.
  group('the three tabs', () {
    Song song(String title, String artist) => Song(
      id: title.hashCode,
      title: title,
      artist: artist,
      album: 'Album',
      duration: 180000,
      filePath: '/musique/$title.mp3',
    );

    final tracks = [
      song('Alors on danse', 'Stromae'),
      song('Papaoutai', 'Stromae'),
      song('Formidable', 'Stromae'),
    ];

    ProviderContainer containerFor(Map<String, LyricsStatus> statuses) {
      final container = ProviderContainer(
        overrides: [
          songListProvider.overrideWith(() => _FixedSongList(tracks)),
          lyricsStatusProvider.overrideWith((ref) async => statuses),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<ProviderContainer> ready() async {
      final container = containerFor({
        '/musique/Alors on danse.mp3': LyricsStatus.none,
        '/musique/Papaoutai.mp3': LyricsStatus.synced,
        '/musique/Formidable.mp3': LyricsStatus.synced,
      });
      // Both, and in this order: the grouping watches each of them, and neither
      // resolves just because the other did.
      await container.read(songListProvider.future);
      await container.read(lyricsStatusProvider.future);
      return container;
    }

    test('each track lands in exactly one tab', () async {
      final container = await ready();
      final grouped = container.read(songsByStatusProvider).requireValue;

      expect(grouped[LyricsStatus.none], hasLength(1));
      expect(grouped[LyricsStatus.synced], hasLength(2));
      expect(grouped[LyricsStatus.plain], isEmpty);
    });

    test('switching tabs does not regroup the library', () async {
      // Identity, not equality: the same list object coming back is proof that
      // no work was redone. An equal-but-new list would mean it was rebuilt.
      final container = await ready();

      final first = container.read(songsByStatusProvider).requireValue;
      container.read(libraryTabProvider.notifier).state = LyricsStatus.synced;
      final second = container.read(songsByStatusProvider).requireValue;

      expect(identical(first, second), isTrue);
    });

    test('and the tab lists are handed straight through', () async {
      final container = await ready();
      final grouped = container.read(songsByStatusProvider).requireValue;

      container.read(libraryTabProvider.notifier).state = LyricsStatus.synced;

      // With no search active, the filter must not copy the list either.
      expect(
        identical(
          container.read(filteredSongsProvider).requireValue,
          grouped[LyricsStatus.synced],
        ),
        isTrue,
      );
    });

    test('the counts come out of the same grouping', () async {
      final container = await ready();
      final counts = container.read(lyricsStatusCountsProvider);

      expect(counts[LyricsStatus.none], 1);
      expect(counts[LyricsStatus.synced], 2);
      expect(counts[LyricsStatus.plain], 0);
    });

    test('search still narrows within the tab, and only within it', () async {
      final container = await ready();
      container.read(libraryTabProvider.notifier).state = LyricsStatus.synced;
      container.read(librarySearchProvider.notifier).state = 'papa';

      final result = container.read(filteredSongsProvider).requireValue;
      expect(result.map((s) => s.title), ['Papaoutai']);

      // The match is in the "none" tab, so this tab shows nothing rather than
      // reaching across.
      container.read(librarySearchProvider.notifier).state = 'danse';
      expect(container.read(filteredSongsProvider).requireValue, isEmpty);
    });

    test('a query cannot straddle the title/artist boundary', () async {
      // The precomputed key joins the two fields, so this checks the join cannot
      // invent a match that the two separate comparisons would not have made.
      final container = await ready();
      container.read(libraryTabProvider.notifier).state = LyricsStatus.synced;
      container.read(librarySearchProvider.notifier).state =
          'papaoutai stromae';

      expect(container.read(filteredSongsProvider).requireValue, isEmpty);
    });

    test('the artist matches as well as the title', () async {
      final container = await ready();
      container.read(libraryTabProvider.notifier).state = LyricsStatus.synced;
      container.read(librarySearchProvider.notifier).state = 'stromae';

      expect(container.read(filteredSongsProvider).requireValue, hasLength(2));
    });

    test('nothing is shown until the statuses are in', () async {
      // Otherwise every track lands under whichever tab happens to be open,
      // which reads as a catalogue that has mis-sorted the whole library.
      final container = containerFor(const {});
      expect(container.read(filteredSongsProvider).isLoading, isTrue);
    });
  });
}

/// A [SongListNotifier] that answers with a fixed list instead of scanning.
class _FixedSongList extends SongListNotifier {
  final List<Song> songs;

  _FixedSongList(this.songs);

  @override
  Future<List<Song>> build() async => songs;
}
