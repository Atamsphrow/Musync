import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:musync/features/player/data/named_queue.dart';

/// Persists the named queues as a single JSON document in SharedPreferences,
/// next to the other small player values (`LastSongStore` works the same
/// way). Corrupt entries are dropped, never thrown: a bad write must not
/// wipe every queue the user built.
class QueueStore {
  static const String _queuesKey = 'named_queues_v1';
  static const String _activeKey = 'named_queues_active_v1';

  /// Returns the stored queues and the active queue id. The caller decides
  /// what to do when the list is empty (the provider recreates the default
  /// queue) or when the active id no longer matches a queue.
  Future<({List<NamedQueue> queues, String? activeId})> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_queuesKey);
    final queues = <NamedQueue>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map<String, dynamic>) {
              final queue = NamedQueue.fromJson(entry);
              if (queue.isValid) queues.add(queue);
            }
          }
        }
      } catch (_) {
        // Corrupt document: start empty rather than lose everything later.
        // The provider recreates the default queue on top of this.
      }
    }
    return (queues: queues, activeId: prefs.getString(_activeKey));
  }

  Future<void> save(List<NamedQueue> queues, String activeId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _queuesKey,
      jsonEncode([for (final q in queues) q.toJson()]),
    );
    await prefs.setString(_activeKey, activeId);
  }
}
