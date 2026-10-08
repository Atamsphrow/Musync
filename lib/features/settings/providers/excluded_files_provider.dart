/// Settings state: the individual files the library scan must skip.
///
/// Mirrors [excludedDirsProvider], but at file level: « exclus ce morceau »
/// hides exactly that file, the rest of its folder untouched.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/library/data/excluded_files_store.dart';
import 'package:musync/features/library/providers/library_provider.dart';

final excludedFilesStoreProvider = Provider<ExcludedFilesStore>(
  (ref) => const ExcludedFilesStore(),
);

final excludedFilesProvider =
    AsyncNotifierProvider<ExcludedFilesNotifier, List<String>>(
      ExcludedFilesNotifier.new,
    );

class ExcludedFilesNotifier extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() => ref.read(excludedFilesStoreProvider).load();

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
      await ref.read(excludedFilesStoreProvider).save(next);
    } catch (error, stack) {
      DebugLog.instance.error(
        'Réglages',
        'Enregistrement des fichiers exclus impossible',
        error: error,
        stackTrace: stack,
      );
    }
    ref.invalidate(songListProvider);
  }

  /// Adds [path] after normalising it. The match is exact, so a plain
  /// membership test is the dedup — no prefix subtlety like with folders.
  Future<void> add(String path) async {
    final file = ExcludedFilesStore.normalise(path);
    if (file.isEmpty) return;
    final current = state.valueOrNull ?? const <String>[];
    if (current.any((f) => f.toLowerCase() == file.toLowerCase())) return;
    await _commit([...current, file]..sort());
  }

  Future<void> remove(String path) async {
    final file = ExcludedFilesStore.normalise(path);
    final current = state.valueOrNull ?? const <String>[];
    await _commit([
      for (final f in current)
        if (f.toLowerCase() != file.toLowerCase()) f,
    ]);
  }
}
