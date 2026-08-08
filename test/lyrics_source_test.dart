// Tests for the LRCLIB source and the multi-source repository.
//
// Everything here runs against a mocked HTTP client: the point is the merging,
// ranking and failure handling around the network, not LRCLIB itself.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lrclib_provider.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

/// One LRCLIB track entry.
Map<String, dynamic> entry({
  required int id,
  String track = 'Ma Chanson',
  String artist = 'Mon Artiste',
  String? album = 'Mon Album',
  int duration = 200,
  String? synced = '[00:01.00]Une ligne',
  String? plain = 'Une ligne',
}) =>
    {
      'id': id,
      'trackName': track,
      'artistName': artist,
      'albumName': album,
      'duration': duration,
      'syncedLyrics': synced,
      'plainLyrics': plain,
    };

/// Serves `/get` and `/search` from the given payloads.
///
/// Responses are built with `Response.bytes` and no content-type, which is how
/// LRCLIB actually answers — and the case where `http`'s `.body` falls back to
/// latin-1 and mangles every accent.
MockClient mockLrclib({
  Object? getPayload,
  int getStatus = 200,
  Object? searchPayload,
  int searchStatus = 200,
  List<Uri>? recordInto,
}) {
  return MockClient((request) async {
    recordInto?.add(request.url);

    final isGet = request.url.path.endsWith('/get');
    final status = isGet ? getStatus : searchStatus;
    final payload = isGet ? getPayload : searchPayload;

    if (status != 200) return http.Response('', status);
    return http.Response.bytes(utf8.encode(jsonEncode(payload)), 200);
  });
}

void main() {
  const query = (title: 'Ma Chanson', artist: 'Mon Artiste');

  Future<List<LyricsSearchResult>> search(
    MockClient client, {
    int? durationMs = 200000,
    String? album = 'Mon Album',
  }) {
    return LrclibSource(client: client).search(
      title: query.title,
      artist: query.artist,
      album: album,
      durationMs: durationMs,
    );
  }

  group('LrclibSource — merging', () {
    test('an exact /get match scores 1.0', () async {
      final results = await search(
        mockLrclib(getPayload: entry(id: 1), searchPayload: const []),
      );

      expect(results, hasLength(1));
      expect(results.first.confidence, 1.0);
      expect(results.first.hasSyncedLyrics, isTrue);
    });

    test('a track returned by both endpoints appears once', () async {
      // The old dedup compared every search hit against the *first* one, so
      // the exact match came back twice.
      final results = await search(mockLrclib(
        getPayload: entry(id: 7),
        searchPayload: [entry(id: 7), entry(id: 8, track: 'Autre')],
      ));

      expect(results.map((r) => r.title), hasLength(2));
      expect(results.where((r) => r.title == 'Ma Chanson'), hasLength(1));
    });

    test('the duplicate keeps the higher confidence', () async {
      final results = await search(mockLrclib(
        getPayload: entry(id: 7),
        searchPayload: [entry(id: 7)],
      ));

      expect(results.single.confidence, 1.0);
    });

    test('results come back best first', () async {
      final results = await search(mockLrclib(
        getPayload: null,
        getStatus: 404,
        searchPayload: [
          entry(id: 1, track: 'Vaguement Proche', artist: 'Quelqu\'un'),
          entry(id: 2),
        ],
      ));

      expect(results.first.title, 'Ma Chanson');
      expect(results.first.confidence,
          greaterThan(results.last.confidence));
    });

    test('a matching duration outranks a mismatched one', () async {
      final results = await search(mockLrclib(
        getStatus: 404,
        searchPayload: [
          entry(id: 1, duration: 999),
          entry(id: 2, duration: 200),
        ],
      ));

      expect(results.first.confidence, greaterThan(results.last.confidence));
    });

    test('skips /get entirely without a duration', () async {
      final calls = <Uri>[];
      await search(
        mockLrclib(searchPayload: const [], recordInto: calls),
        durationMs: null,
      );

      expect(calls.map((u) => u.path), everyElement(endsWith('/search')));
    });
  });

  group('LrclibSource — content', () {
    test('accents survive: the body is decoded as UTF-8', () async {
      // Reading `response.body` instead of `bodyBytes` turns "éàü" into mojibake
      // whenever the server omits the charset — which LRCLIB does.
      final results = await search(mockLrclib(
        getPayload: entry(
          id: 1,
          track: 'Été à Nîmes',
          artist: 'Cœur',
          synced: '[00:01.00]Où êtes-vous ?',
        ),
        searchPayload: const [],
      ));

      expect(results.first.title, 'Été à Nîmes');
      expect(results.first.artist, 'Cœur');
      expect(results.first.syncedLyrics!.lines.first.text, 'Où êtes-vous ?');
    });

    test('parses the LRC into timed lines', () async {
      final results = await search(mockLrclib(
        getPayload: entry(
          id: 1,
          synced: '[00:01.50]Une\n[00:03.00]Deux',
        ),
        searchPayload: const [],
      ));

      final lines = results.first.syncedLyrics!.lines;
      expect(lines, hasLength(2));
      expect(lines.first.timestamp, const Duration(milliseconds: 1500));
    });

    test('an entry with no lyrics at all is dropped', () async {
      // LRCLIB returns instrumentals with both fields empty.
      final results = await search(mockLrclib(
        getStatus: 404,
        searchPayload: [
          entry(id: 1, synced: null, plain: null),
          entry(id: 2),
        ],
      ));

      expect(results, hasLength(1));
      expect(results.single.hasSyncedLyrics, isTrue);
    });

    test('a plain-only entry survives, flagged as unsynced', () async {
      final results = await search(mockLrclib(
        getPayload: entry(id: 1, synced: null),
        searchPayload: const [],
      ));

      expect(results.single.hasSyncedLyrics, isFalse);
      expect(results.single.hasUnsyncedLyrics, isTrue);
    });
  });

  group('LrclibSource — failures', () {
    test('404 on /get is "no match", not an error', () async {
      final results = await search(mockLrclib(
        getStatus: 404,
        searchPayload: [entry(id: 1)],
      ));

      expect(results, hasLength(1));
    });

    test('a server error is raised, not swallowed as "no results"', () async {
      // The old source caught everything and returned [], so a dead network
      // looked exactly like a song nobody has transcribed.
      expect(
        () => search(mockLrclib(getStatus: 500, searchStatus: 500)),
        throwsA(isA<LyricsSourceException>()),
      );
    });

    test('an unparseable body is raised as a source failure', () async {
      final client = MockClient(
        (request) async => http.Response('pas du json', 200),
      );

      expect(
        () => search(client),
        throwsA(isA<LyricsSourceException>()),
      );
    });

    test('a network drop is raised as a source failure', () async {
      final client = MockClient(
        (request) async => throw http.ClientException('connexion perdue'),
      );

      expect(
        () => search(client),
        throwsA(isA<LyricsSourceException>()),
      );
    });
  });

  group('LyricsRepository — multi-source', () {
    test('one failing source does not take the search down', () async {
      final repo = LyricsRepository(sources: [
        _FailingSource(),
        _StubSource([_result('Depuis la source qui marche', 0.9)]),
      ]);

      final results = await repo.searchAll(
        title: query.title,
        artist: query.artist,
      );

      expect(results.map((r) => r.title), ['Depuis la source qui marche']);
    });

    test('every source failing does throw — there is nothing to show', () async {
      final repo = LyricsRepository(sources: [_FailingSource(), _FailingSource()]);

      expect(
        () => repo.searchAll(title: query.title, artist: query.artist),
        throwsA(isA<LyricsSourceException>()),
      );
    });

    test('results from several sources are merged and ranked together', () async {
      final repo = LyricsRepository(sources: [
        _StubSource([_result('Moyenne', 0.5)]),
        _StubSource([_result('Excellente', 0.95)]),
      ]);

      final results = await repo.searchAll(
        title: query.title,
        artist: query.artist,
      );

      expect(results.map((r) => r.title), ['Excellente', 'Moyenne']);
    });

    test('empty results from a reachable source are not an error', () async {
      final repo = LyricsRepository(sources: [_StubSource(const [])]);

      expect(
        await repo.searchAll(title: query.title, artist: query.artist),
        isEmpty,
      );
    });

    test('an empty query short-circuits before any request', () async {
      final repo = LyricsRepository(sources: [_FailingSource()]);

      expect(await repo.searchAll(title: '  ', artist: ''), isEmpty);
    });
  });
}

LyricsSearchResult _result(String title, double confidence) => LyricsSearchResult(
      source: 'Test',
      title: title,
      artist: 'Artiste',
      syncedLyrics: SyncedLyrics([
        const LyricLine(timestamp: Duration(seconds: 1), text: 'ligne'),
      ]),
      confidence: confidence,
    );

class _StubSource extends LyricsSource {
  final List<LyricsSearchResult> results;

  _StubSource(this.results);

  @override
  String get name => 'Stub';

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
  }) async =>
      results;
}

class _FailingSource extends LyricsSource {
  @override
  String get name => 'Cassée';

  @override
  Future<List<LyricsSearchResult>> search({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
  }) async =>
      throw const LyricsSourceException('Cassée', 'injoignable');
}
