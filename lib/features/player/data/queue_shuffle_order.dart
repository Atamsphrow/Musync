/// The shuffle order of Musync's playback queue.
///
/// just_audio's [DefaultShuffleOrder] puts every inserted item at a random
/// position of the shuffled order — including the one a move re-inserts.
/// With shuffle on, that made two queue actions lie:
///
///  * « Lire ensuite » put the track anywhere in the shuffled run instead of
///    right after the current one;
///  * dragging a row in the queue (or « Lire ensuite » on a track already
///    queued, which is a move) threw that track to a random new spot.
///
/// This order behaves exactly like the default one — same shuffle, same
/// random placement — except when the service asks, just before a mutation,
/// for one of the two placements above. Both requests are consumed by the
/// very next insert, which just_audio makes synchronously at the start of
/// `ConcatenatingAudioSource.insert`/`move`, before any await.
library;

import 'dart:math';

import 'package:just_audio/just_audio.dart';

class QueueShuffleOrder extends ShuffleOrder {
  QueueShuffleOrder({Random? random}) : _random = random ?? Random();

  final Random _random;

  @override
  final List<int> indices = <int>[];

  /// Child index the next insert goes right after, in the shuffled order.
  /// Tracked through removals and inserts so it keeps naming the same item.
  int? _anchorChild;

  /// Set by [keepSlotOnNextMove]: the next single-item removal records its
  /// slot, and the insert that follows puts the item back in that slot.
  bool _keepSlot = false;
  int? _freedSlot;

  /// The next insert lands right after [childIndex] in the shuffled order —
  /// « play next » under shuffle.
  void placeNextInsertAfter(int childIndex) {
    _anchorChild = childIndex;
    _keepSlot = false;
    _freedSlot = null;
  }

  /// The next move keeps the item's place in the shuffled order: a drag in
  /// the (plain-order) queue list reorders the list, not the shuffled run.
  void keepSlotOnNextMove() {
    _keepSlot = true;
    _freedSlot = null;
    _anchorChild = null;
  }

  @override
  void shuffle({int? initialIndex}) {
    // Same as DefaultShuffleOrder: random order, current item first.
    if (indices.length <= 1) return;
    indices.shuffle(_random);
    if (initialIndex == null) return;
    final swapPos = indices.indexOf(initialIndex);
    if (swapPos < 0) return;
    indices[swapPos] = indices[0];
    indices[0] = initialIndex;
  }

  @override
  void insert(int index, int count) {
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) indices[i] += count;
    }
    final anchor = _anchorChild;
    _anchorChild = null;
    final freedSlot = _freedSlot;
    final keepSlot = _keepSlot;
    _keepSlot = false;
    _freedSlot = null;

    if (keepSlot && freedSlot != null && count == 1) {
      indices.insert(freedSlot.clamp(0, indices.length), index);
      return;
    }
    if (anchor != null) {
      final shifted = anchor >= index ? anchor + count : anchor;
      final pos = indices.indexOf(shifted);
      var at = pos < 0 ? indices.length : pos + 1;
      for (var i = 0; i < count; i++) {
        indices.insert(at++, index + i);
      }
      return;
    }
    // Default behaviour: each new item at a random position.
    for (var i = 0; i < count; i++) {
      indices.insert(_random.nextInt(indices.length + 1), index + i);
    }
  }

  @override
  void removeRange(int start, int end) {
    final count = end - start;
    if (_keepSlot && count == 1) {
      final slot = indices.indexOf(start);
      _freedSlot = slot < 0 ? null : slot;
    }
    final anchor = _anchorChild;
    if (anchor != null) {
      if (anchor >= start && anchor < end) {
        _anchorChild = null; // The anchor itself is going away.
      } else if (anchor >= end) {
        _anchorChild = anchor - count;
      }
    }
    indices.removeWhere((i) => i >= start && i < end);
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= end) indices[i] -= count;
    }
  }

  @override
  void clear() {
    indices.clear();
    _anchorChild = null;
    _keepSlot = false;
    _freedSlot = null;
  }
}
