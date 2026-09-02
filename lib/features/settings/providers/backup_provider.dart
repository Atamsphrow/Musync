/// The tag backups behind "Annuler".
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/tag_backup.dart';

final tagBackupStoreProvider = Provider<TagBackupStore>(
  (ref) => TagBackupStore(),
);

/// Recorded writes, newest first.
///
/// Invalidated after a write and after a restore, which is what keeps the
/// history screen honest without it having to poll.
final tagBackupsProvider = FutureProvider<List<TagBackup>>(
  (ref) => ref.read(tagBackupStoreProvider).list(),
);
