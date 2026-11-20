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
