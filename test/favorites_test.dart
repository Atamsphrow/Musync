// Favourites: stored by path, toggled from the player, listed newest first
// with only the tracks still in the library.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/favorites_store.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/library/providers/favorites_provider.dart';
import 'package:musync/features/library/providers/library_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(int id) => Song(
      id: id,
      title: 'T$id',
      artist: 'A',
      album: 'B',
      duration: 1000,
      filePath: '/music/$id.mp3',
    );

class _FixedSongList extends SongListNotifier {
  _FixedSongList(this.songs);
  final List<Song> songs;

  @override
  Future<List<Song>> build() async => songs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the store drops blanks and duplicates, keeps the order', () async {
    SharedPreferences.setMockInitialValues({
      FavoritesStore.prefsKey: ['/a.mp3', ' ', '/b.mp3', '/a.mp3'],
    });
    expect(await const FavoritesStore().load(), ['/a.mp3', '/b.mp3']);
  });

  test('toggle adds then removes, and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(favoritesProvider.notifier);
    await Future<void>.delayed(Duration.zero); // Let the load land.

    expect(await notifier.toggle(_song(1)), isTrue);
    expect(container.read(favoritesProvider), ['/music/1.mp3']);
    expect(await const FavoritesStore().load(), ['/music/1.mp3']);

    expect(await notifier.toggle(_song(1)), isFalse);
    expect(container.read(favoritesProvider), isEmpty);
  });

  test('a reload (import) replaces the list, it does not merge', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(favoritesProvider);
    await Future<void>.delayed(Duration.zero);
    await container.read(favoritesProvider.notifier).toggle(_song(1));

    // An import writes the preference, then invalidates the provider.
    await const FavoritesStore().save(['/imported.mp3']);
    container.invalidate(favoritesProvider);
    container.read(favoritesProvider);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(favoritesProvider), ['/imported.mp3']);
  });

  group('reconcileFavorites', () {
    Song at(int id, String path, {String? title, String artist = 'A'}) =>
        _song(id).copyWith(filePath: path, title: title, artist: artist);
    FavoriteKey keyOf(int id, {String? title, int duration = 1000}) =>
        FavoriteKey(
          id: id,
          title: title ?? 'T$id',
          artist: 'A',
          durationMs: duration,
        );
    bool gone(String _) => false;

    test('a listed favourite stays and gets its key', () {
      final result = reconcileFavorites(
        favorites: ['/music/1.mp3'],
        keys: const {},
        songs: [_song(1)],
        fileExists: gone,
      );
      expect(result.favorites, ['/music/1.mp3']);
      expect(result.keys, {'/music/1.mp3': FavoriteKey.of(_song(1))});
    });

    test('renamed elsewhere: same id and title, followed in place', () {
      final result = reconcileFavorites(
        favorites: ['/music/2.mp3', '/music/old.mp3', '/music/3.mp3'],
        keys: {'/music/old.mp3': keyOf(1)},
        songs: [_song(2), at(1, '/music/new.mp3'), _song(3)],
        fileExists: gone,
      );
      expect(result.favorites, [
        '/music/2.mp3',
        '/music/new.mp3',
        '/music/3.mp3',
      ]);
      expect(result.keys.keys, contains('/music/new.mp3'));
      expect(result.keys.keys, isNot(contains('/music/old.mp3')));
    });

    test('an id given to another track is not followed', () {
      final result = reconcileFavorites(
        favorites: ['/music/old.mp3'],
        keys: {'/music/old.mp3': keyOf(1)},
        songs: [at(1, '/music/other.mp3', title: 'Autre chose')],
        fileExists: gone,
      );
      expect(result.favorites, ['/music/old.mp3']);
      expect(result.keys, {'/music/old.mp3': keyOf(1)});
    });

    test('new id: the one track with the same title, artist, length', () {
      final result = reconcileFavorites(
        favorites: ['/music/old.mp3'],
        keys: {'/music/old.mp3': keyOf(1, duration: 1500)},
        songs: [at(9, '/moved/T1.mp3', title: ' t1 ')],
        fileExists: gone,
      );
      expect(result.favorites, ['/moved/T1.mp3']);
    });

    test('two such tracks: nothing is guessed', () {
      final result = reconcileFavorites(
        favorites: ['/music/old.mp3'],
        keys: {'/music/old.mp3': keyOf(1)},
        songs: [at(8, '/a/T1.mp3', title: 'T1'), at(9, '/b/T1.mp3', title: 'T1')],
        fileExists: gone,
      );
      expect(result.favorites, ['/music/old.mp3']);
    });

    test('the old file still there (excluded folder): left alone', () {
      final result = reconcileFavorites(
        favorites: ['/music/old.mp3'],
        keys: {'/music/old.mp3': keyOf(1)},
        songs: [at(1, '/music/copy.mp3')],
        fileExists: (path) => path == '/music/old.mp3',
      );
      expect(result.favorites, ['/music/old.mp3']);
    });

    test('a track that is already a favourite is never taken', () {
      final result = reconcileFavorites(
        favorites: ['/music/old.mp3', '/music/new.mp3'],
        keys: {'/music/old.mp3': keyOf(1)},
        songs: [at(1, '/music/new.mp3')],
        fileExists: gone,
      );
      expect(result.favorites, ['/music/old.mp3', '/music/new.mp3']);
    });

    test('no key (gone before it was noted): waits for its file', () {
      final result = reconcileFavorites(
        favorites: ['/music/old.mp3'],
        keys: const {},
        songs: [at(1, '/music/new.mp3')],
        fileExists: gone,
      );
      expect(result.favorites, ['/music/old.mp3']);
      expect(result.keys, isEmpty);
    });
  });

  group('FavoritesNotifier follows moved files', () {
    test('a scan finds a favourite renamed elsewhere, and saves it', () async {
      SharedPreferences.setMockInitialValues({
        FavoritesStore.prefsKey: ['/music/old.mp3'],
      });
      await const FavoritesStore().saveKeys({
        '/music/old.mp3': FavoriteKey.of(_song(1)),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(favoritesProvider.notifier);

      await notifier.reconcile([_song(1)], fileExists: (_) => false);

      expect(container.read(favoritesProvider), ['/music/1.mp3']);
      expect(await const FavoritesStore().load(), ['/music/1.mp3']);
      expect((await const FavoritesStore().loadKeys()).keys, ['/music/1.mp3']);
    });

    test('an empty scan changes nothing', () async {
      SharedPreferences.setMockInitialValues({
        FavoritesStore.prefsKey: ['/music/old.mp3'],
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(favoritesProvider.notifier)
          .reconcile(const [], fileExists: (_) => false);
      expect(container.read(favoritesProvider), ['/music/old.mp3']);
    });

    test('a rename by the app moves the favourite and its key', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(favoritesProvider.notifier);
      await notifier.movePath('/x.mp3', '/y.mp3'); // Not a favourite: no-op.
      await notifier.toggle(_song(1));
      expect(
        (await const FavoritesStore().loadKeys()).keys,
        ['/music/1.mp3'],
      );

      await notifier.movePath('/music/1.mp3', '/music/renamed.mp3');

      expect(container.read(favoritesProvider), ['/music/renamed.mp3']);
      expect(await const FavoritesStore().load(), ['/music/renamed.mp3']);
      expect(
        (await const FavoritesStore().loadKeys()).keys,
        ['/music/renamed.mp3'],
      );
    });
  });

  test('the view lists library tracks only, most recent first', () async {
    SharedPreferences.setMockInitialValues({
      FavoritesStore.prefsKey: ['/music/1.mp3', '/gone.mp3', '/music/2.mp3'],
    });
    final container = ProviderContainer(
      overrides: [
        songListProvider.overrideWith(
          () => _FixedSongList([_song(1), _song(2), _song(3)]),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(favoritesProvider);
    await container.read(songListProvider.future);
    await Future<void>.delayed(Duration.zero);

    final songs = container.read(favoriteSongsProvider).valueOrNull;
    expect(songs?.map((s) => s.id), [2, 1]);
  });
}
