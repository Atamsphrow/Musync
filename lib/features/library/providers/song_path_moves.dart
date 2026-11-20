/// What follows a track when the app renames or moves its file.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/library/providers/favorites_provider.dart';
import 'package:musync/features/library/providers/listening_history_provider.dart';

/// The app renamed or moved [oldPath] to [newPath]: what is kept by path —
/// the favourite, the listening history — follows the file. Both save
/// their own errors to the journal; this never throws on their account.
Future<void> followMovedSong(Ref ref, String oldPath, String newPath) =>
    Future.wait([
      ref.read(favoritesProvider.notifier).movePath(oldPath, newPath),
      ref.read(listeningHistoryProvider.notifier).movePath(oldPath, newPath),
    ]);
