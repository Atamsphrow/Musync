import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/named_queue.dart';
import 'package:musync/features/player/data/queue_store.dart';
import 'package:musync/features/player/providers/player_provider.dart';

/// Id of the queue that always exists and can never be deleted.
const String kDefaultQueueId = 'main';

/// Name given to the default queue. Renamable by the user, like any queue.
const String kDefaultQueueName = 'File principale';

/// Immutable view of the queues the user manages.
class NamedQueuesState {
  final List<NamedQueue> queues;
  final String activeId;
  final bool loaded;

  const NamedQueuesState({
    this.queues = const [],
    this.activeId = kDefaultQueueId,
    this.loaded = false,
  });

  NamedQueue? get active {
    for (final q in queues) {
      if (q.id == activeId) return q;
    }
    return null;
  }

  NamedQueuesState copyWith({
    List<NamedQueue>? queues,
    String? activeId,
    bool? loaded,
  }) {
    return NamedQueuesState(
      queues: queues ?? this.queues,
      activeId: activeId ?? this.activeId,
      loaded: loaded ?? this.loaded,
    );
  }
}

final namedQueuesProvider =
    NotifierProvider<NamedQueuesController, NamedQueuesState>(
  NamedQueuesController.new,
);

/// Owns the named playback queues: create, rename, delete, activate.
///
/// A queue is a snapshot — activating it reloads that snapshot into the
/// player via [AudioPlayerService.playSong]. While a queue is active, the
/// provider keeps its stored index in step with the player's current index,
/// so re-activating a queue later resumes where playback actually left off
/// rather than where the snapshot was taken.
class NamedQueuesController extends Notifier<NamedQueuesState> {
  final QueueStore _store = QueueStore();

  /// Serializes mutations against the initial load and against each other.
  Future<void> _gate = Future.value();

  @override
  NamedQueuesState build() {
    unawaited(_load());
    // Keep the active queue's stored index honest while it plays. The
    // player's index is authoritative: the stored one is only a resume
    // position for later activations.
    ref.listen<AsyncValue<int?>>(currentIndexProvider, (previous, next) {
      final index = next.value;
      if (index == null || index < 0) return;
      final current = state;
      final active = current.active;
      if (active == null || active.isEmpty) return;
      if (index >= active.length || index == active.currentIndex) return;
      final updated = active.copyWith(currentIndex: index);
      state = current.copyWith(
        queues: [
          for (final q in current.queues) q.id == active.id ? updated : q,
        ],
      );
      unawaited(_persist());
    });
    return const NamedQueuesState();
  }

  Future<void> _load() async {
    final stored = await _store.load();
    var queues = stored.queues;
    if (!queues.any((q) => q.id == kDefaultQueueId)) {
      queues = [
        const NamedQueue(id: kDefaultQueueId, name: kDefaultQueueName),
        ...queues,
      ];
    }
    var activeId = stored.activeId;
    if (activeId == null || !queues.any((q) => q.id == activeId)) {
      activeId = kDefaultQueueId;
    }
    state = NamedQueuesState(
      queues: List.unmodifiable(queues),
      activeId: activeId,
      loaded: true,
    );
    await _persist();
  }

  Future<void> _persist() =>
      _store.save(state.queues, state.activeId);

  /// Runs [action] after the previous mutation finished, so overlapping UI
  /// taps cannot interleave two writes and lose one.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _gate.then((_) => action());
    _gate = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Creates a queue capturing the player's current queue and position.
  /// Returns the new queue's id. A name already in use gets a numeric
  /// suffix rather than failing or colliding.
  Future<String> create(String name) => _serialized(() async {
        final trimmed = name.trim();
        final service = ref.read(audioPlayerServiceProvider);
        final queue = NamedQueue(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: _uniqueName(trimmed.isEmpty ? 'Nouvelle file' : trimmed),
          songs: List.of(service.queue),
          currentIndex: service.currentIndex,
        );
        state = state.copyWith(queues: [...state.queues, queue]);
        await _persist();
        return queue.id;
      });

  /// Creates a queue from an arbitrary song list (search results, a folder,
  /// …) instead of the player's current queue. Playback starts at the first
  /// song. Returns the new queue's id.
  Future<String> createFromSongs(String name, List<Song> songs) =>
      _serialized(() async {
        final trimmed = name.trim();
        final queue = NamedQueue(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: _uniqueName(trimmed.isEmpty ? 'Nouvelle file' : trimmed),
          songs: List.of(songs),
          currentIndex: 0,
        );
        state = state.copyWith(queues: [...state.queues, queue]);
        await _persist();
        return queue.id;
      });

  /// Renames a queue. Returns false when the name is blank or the queue
  /// does not exist.
  Future<bool> rename(String id, String name) => _serialized(() async {
        final trimmed = name.trim();
        if (trimmed.isEmpty) return false;
        final current = state;
        final index = current.queues.indexWhere((q) => q.id == id);
        if (index < 0) return false;
        if (current.queues[index].name == trimmed) return true;
        final renamed = current.queues[index].copyWith(
          name: _uniqueName(trimmed, exceptId: id),
        );
        final queues = List<NamedQueue>.of(current.queues);
        queues[index] = renamed;
        state = current.copyWith(queues: List.unmodifiable(queues));
        await _persist();
        return true;
      });

  /// Deletes a queue. The default queue can never be deleted; deleting the
  /// active queue falls back to the default one. Returns false when the id
  /// is the default queue or unknown.
  Future<bool> delete(String id) => _serialized(() async {
        if (id == kDefaultQueueId) return false;
        final current = state;
        if (!current.queues.any((q) => q.id == id)) return false;
        final queues =
            current.queues.where((q) => q.id != id).toList(growable: false);
        final activeId =
            current.activeId == id ? kDefaultQueueId : current.activeId;
        state = current.copyWith(
          queues: List.unmodifiable(queues),
          activeId: activeId,
        );
        await _persist();
        return true;
      });

  /// Makes [id] the active queue and reloads its snapshot into the player.
  ///
  /// An empty queue only switches the active marker: there is nothing to
  /// load and playback is left untouched. A non-empty queue starts its
  /// resume track through the existing `playSong` path, so artwork warmup,
  /// the media notification and the current-song stream all behave exactly
  /// like a normal play.
  Future<void> activate(String id) async {
    final queue = await _serialized(() async {
      final current = state;
      NamedQueue? target;
      for (final q in current.queues) {
        if (q.id == id) {
          target = q;
          break;
        }
      }
      if (target == null || target.id == current.activeId) return target;
      state = current.copyWith(activeId: target.id);
      await _persist();
      return target;
    });
    if (queue == null || queue.isEmpty) return;
    final songs = List<Song>.of(queue.songs);
    final index = queue.resumeIndex;
    await ref
        .read(audioPlayerServiceProvider)
        .playSong(songs[index], queue: songs, index: index);
  }

  /// Replaces a queue's snapshot with the player's current queue and
  /// position. Returns false when the queue does not exist.
  Future<bool> replaceWithCurrent(String id) => _serialized(() async {
        final current = state;
        final index = current.queues.indexWhere((q) => q.id == id);
        if (index < 0) return false;
        final service = ref.read(audioPlayerServiceProvider);
        final queues = List<NamedQueue>.of(current.queues);
        queues[index] = queues[index].copyWith(
          songs: List.of(service.queue),
          currentIndex: service.currentIndex,
        );
        state = current.copyWith(queues: List.unmodifiable(queues));
        await _persist();
        return true;
      });

  /// Copies the player's current queue and position into the active queue,
  /// then persists. The player is authoritative after a reorder, a remove
  /// or a play-next: without this, activating the queue later would restore
  /// the stale snapshot taken before the edit.
  Future<void> syncActiveFromPlayer() => _serialized(() async {
        final current = state;
        final active = current.active;
        if (active == null) return;
        final service = ref.read(audioPlayerServiceProvider);
        final queues = List<NamedQueue>.of(current.queues);
        final index = queues.indexWhere((q) => q.id == active.id);
        if (index < 0) return;
        queues[index] = queues[index].copyWith(
          songs: List.of(service.queue),
          currentIndex: service.currentIndex,
        );
        state = current.copyWith(queues: List.unmodifiable(queues));
        await _persist();
      });

  String _uniqueName(String base, {String? exceptId}) {
    final taken = {
      for (final q in state.queues)
        if (q.id != exceptId) q.name.toLowerCase(),
    };
    if (!taken.contains(base.toLowerCase())) return base;
    var n = 2;
    while (taken.contains('${base.toLowerCase()} ($n)')) {
      n++;
    }
    return '$base ($n)';
  }
}
