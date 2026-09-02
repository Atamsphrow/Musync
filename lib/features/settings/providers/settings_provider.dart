/// Settings state: the user's list of lyrics sources (plan P5).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/features/settings/data/lyrics_source_config.dart';

final lyricsSourceStoreProvider = Provider<LyricsSourceStore>(
  (ref) => LyricsSourceStore(),
);

final lyricsSourcesProvider =
    AsyncNotifierProvider<LyricsSourcesNotifier, List<LyricsSourceConfig>>(
      LyricsSourcesNotifier.new,
    );

class LyricsSourcesNotifier extends AsyncNotifier<List<LyricsSourceConfig>> {
  @override
  Future<List<LyricsSourceConfig>> build() =>
      ref.read(lyricsSourceStoreProvider).load();

  /// Applies [next] and persists it.
  ///
  /// The state is set before the write completes so the list never appears to
  /// lag behind a switch the user just flicked; a failed write is reported to
  /// the debug log rather than thrown, since the change is already true in the
  /// app and losing it only costs the next launch.
  Future<void> _commit(List<LyricsSourceConfig> next) async {
    state = AsyncValue.data(next);
    try {
      await ref.read(lyricsSourceStoreProvider).save(next);
    } catch (error, stack) {
      DebugLog.instance.error(
        'Réglages',
        'Enregistrement des sources impossible',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> add({required String name, required String baseUrl}) async {
    final current = state.valueOrNull ?? const [lrclibDefault];
    await _commit([
      ...current,
      LyricsSourceConfig(
        // Wall-clock microseconds: unique enough for a list a person maintains
        // by hand, and it avoids pulling in a uuid package for four entries.
        id: 'custom-${DateTime.now().microsecondsSinceEpoch}',
        name: name.trim(),
        baseUrl: normaliseBaseUrl(baseUrl),
      ),
    ]);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final current = state.valueOrNull ?? const [lrclibDefault];
    await _commit([
      for (final config in current)
        if (config.id == id) config.copyWith(enabled: enabled) else config,
    ]);
  }

  Future<void> edit(String id, {String? name, String? baseUrl}) async {
    final current = state.valueOrNull ?? const [lrclibDefault];
    await _commit([
      for (final config in current)
        if (config.id == id && !config.isBuiltIn)
          config.copyWith(
            name: name?.trim(),
            baseUrl: baseUrl == null ? null : normaliseBaseUrl(baseUrl),
          )
        else
          config,
    ]);
  }

  /// Removes a source. The bundled one is ignored rather than refused loudly —
  /// the UI never offers it, so reaching here means a caller got it wrong.
  Future<void> remove(String id) async {
    final current = state.valueOrNull ?? const [lrclibDefault];
    await _commit([
      for (final config in current)
        if (config.id != id || config.isBuiltIn) config,
    ]);
  }
}

/// Trims a URL into the form the LRCLIB client expects.
///
/// People paste `https://lrclib.net/` or `https://lrclib.net/api/` about as
/// often as the exact form, and a trailing slash would produce `//get`. The
/// `/api` suffix is added when missing, since that is where the endpoints live
/// on every deployment.
String normaliseBaseUrl(String raw) {
  var url = raw.trim();
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  if (url.isEmpty) return url;
  if (!url.endsWith('/api')) url = '$url/api';
  return url;
}

/// Whether [raw] could be a base URL at all. Returns a message, or null if fine.
///
/// Deliberately shallow: this catches typing mistakes, not unreachable hosts.
/// Whether a server answers is something only a real search can tell, and the
/// search already reports that per source.
String? validateBaseUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 'Indiquez une adresse.';

  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'Adresse invalide. Exemple : https://lrclib.net';
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return 'Seul http ou https est accepté.';
  }
  return null;
}
