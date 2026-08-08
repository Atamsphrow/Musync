import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/id3_reader.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/providers/player_provider.dart';

final currentLyricsProvider = FutureProvider<({SyncedLyrics? synced, UnsyncedLyrics? unsynced})>((ref) async {
  final currentSong = ref.watch(currentSongProvider);
  if (currentSong == null) {
    return (synced: null, unsynced: null);
  }
  return await Id3Reader.readLyrics(currentSong.filePath);
});

final currentLineIndexProvider = Provider<int?>((ref) {
  final lyricsAsync = ref.watch(currentLyricsProvider);
  final positionAsync = ref.watch(positionProvider);
  
  final syncedLyrics = lyricsAsync.valueOrNull?.synced;
  final position = positionAsync.valueOrNull;
  
  if (syncedLyrics == null || position == null) {
    return null;
  }
  
  return syncedLyrics.getLineAt(position);
});
