import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/lyrics/data/lyrics_repository.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';

final lyricsRepositoryProvider = Provider<LyricsRepository>((ref) {
  return LyricsRepository();
});

final lyricsSearchResultsProvider = StateProvider<List<LyricsSearchResult>>((ref) => []);
final lyricsSearchLoadingProvider = StateProvider<bool>((ref) => false);
final lyricsSearchErrorProvider = StateProvider<String?>((ref) => null);

Future<void> performLyricsSearch(
  WidgetRef ref, {
  required String title,
  required String artist,
  String? album,
  int? durationMs,
}) async {
  ref.read(lyricsSearchLoadingProvider.notifier).state = true;
  ref.read(lyricsSearchErrorProvider.notifier).state = null;
  ref.read(lyricsSearchResultsProvider.notifier).state = [];

  try {
    final repository = ref.read(lyricsRepositoryProvider);
    final results = await repository.searchAll(
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
    );
    ref.read(lyricsSearchResultsProvider.notifier).state = results;
  } on LyricsSourceException catch (e) {
    // The source already phrased this for the user; `toString()` would put the
    // class name and the source id in front of it.
    ref.read(lyricsSearchErrorProvider.notifier).state = e.message;
  } catch (e) {
    ref.read(lyricsSearchErrorProvider.notifier).state =
        'Erreur inattendue : $e';
  } finally {
    ref.read(lyricsSearchLoadingProvider.notifier).state = false;
  }
}
