/// Settings state: the directories the library scan must skip.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/excluded_dirs_store.dart';
import 'package:musync/features/library/providers/library_provider.dart';

final excludedDirsStoreProvider = Provider<ExcludedDirsStore>(
  (ref) => const ExcludedDirsStore(),
);

final excludedDirsProvider =
    AsyncNotifierProvider<ExcludedDirsNotifier, List<String>>(
      ExcludedDirsNotifier.new,
    );

class ExcludedDirsNotifier extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() => ref.read(excludedDirsStoreProvider).load();

  /// Applies [next] and persists it, then rescans the library so the change
  /// takes effect immediately.
  ///
  /// The state is set before the write completes so the list never appears to
  /// lag behind a tap the user just made; a failed write is reported to the
  /// debug log rather than thrown, since the change is already true in the
  /// app and losing it only costs the next launch.
  Future<void> _commit(List<String> next) async {
    state = AsyncValue.data(next);
    try {
      await ref.read(excludedDirsStoreProvider).save(next);
    } catch (error, stack) {
      DebugLog.instance.error(
        'Réglages',
        'Enregistrement des dossiers exclus impossible',
        error: error,
        stackTrace: stack,
      );
    }
    ref.invalidate(songListProvider);
  }

  /// Adds [path] after normalising it. A path already covered by the list is
  /// ignored — two spellings of the same folder would only confuse the rescan.
  Future<void> add(String path) async {
    final dir = ExcludedDirsStore.normalise(path);
    if (dir.isEmpty) return;
    final current = state.valueOrNull ?? const <String>[];
    if (ExcludedDirsStore.isExcluded(dir, current)) return;
    await _commit([...current, dir]..sort());
  }

  Future<void> remove(String path) async {
    final dir = ExcludedDirsStore.normalise(path);
    final current = state.valueOrNull ?? const <String>[];
    await _commit([
      for (final d in current)
        if (d != dir) d,
    ]);
  }
}
