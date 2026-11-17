// The queue's shuffle order: default random behaviour, except for the two
// placements the service asks for — « play next » right after the current
// item, and a drag that keeps the moved item's place in the shuffled run.
//
// The mutations below mirror what just_audio's ConcatenatingAudioSource does
// to its order: insert(index, 1) for an insert, removeRange(cur, cur + 1)
// then insert(new, 1) for a move.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/player/data/queue_shuffle_order.dart';

/// An order over [length] children, shuffled into a known permutation.
QueueShuffleOrder _orderOf(List<int> permutation) {
  final order = QueueShuffleOrder(random: Random(1))
    ..insert(0, permutation.length);
  order.indices
    ..clear()
    ..addAll(permutation);
  return order;
}

void main() {
  test('a plain insert keeps every index and offsets the later ones', () {
    final order = _orderOf([2, 0, 3, 1]);
    order.insert(1, 1);
    expect(order.indices.toSet(), {0, 1, 2, 3, 4});
    expect(order.indices.length, 5);
    // The old 1, 2, 3 became 2, 3, 4 and kept their relative order.
    final old = order.indices.where((i) => i != 1).toList();
    expect(old, [3, 0, 4, 2]);
  });

  test('play next under shuffle: the new item follows the current one', () {
    // Shuffled run 2 → 0 → 3 → 1, current item is child 0.
    final order = _orderOf([2, 0, 3, 1]);
    // « Lire ensuite » inserts the new child at plain index 1 (current + 1).
    order.placeNextInsertAfter(0);
    order.insert(1, 1);
    // Old 3 → 4, old 2 → 3, old 1 → 2; the new item (1) right after 0.
    expect(order.indices, [3, 0, 1, 4, 2]);
  });

  test('play next of a queued track (a move) also lands after current', () {
    // Children 0..4, shuffled run 4 → 1 → 0 → 3 → 2, current is child 1.
    final order = _orderOf([4, 1, 0, 3, 2]);
    // The service moves child 3 to plain index 2 (current + 1).
    order.placeNextInsertAfter(1);
    order.removeRange(3, 4);
    order.insert(2, 1);
    final current = order.indices.indexOf(1);
    expect(order.indices[current + 1], 2, reason: 'moved track plays next');
    expect(order.indices.toSet(), {0, 1, 2, 3, 4});
  });

  test('the anchor follows its item when a removal shifts it', () {
    // Current is child 3; child 0 is removed first, so it becomes child 2.
    final order = _orderOf([3, 0, 1, 2]);
    order.placeNextInsertAfter(3);
    order.removeRange(0, 1);
    order.insert(3, 1);
    final current = order.indices.indexOf(2);
    expect(order.indices[current + 1], 3);
  });

  test('a drag keeps the moved item at its place in the shuffled run', () {
    // Shuffled run 2 → 0 → 3 → 1; the user drags child 3 to plain index 0.
    final order = _orderOf([2, 0, 3, 1]);
    order.keepSlotOnNextMove();
    order.removeRange(3, 4);
    order.insert(0, 1);
    // Children renumber (0→1, 1→2, 2→3, moved 3→0), the run stays the same
    // songs in the same order.
    expect(order.indices, [3, 1, 0, 2]);
  });

  test('requests are one-shot: the next insert is random again', () {
    final order = _orderOf([0, 1, 2]);
    order.placeNextInsertAfter(0);
    order.insert(3, 1);
    expect(order.indices, [0, 3, 1, 2]);
    // No request now: still a valid permutation, whatever the position.
    order.insert(4, 1);
    expect(order.indices.toSet(), {0, 1, 2, 3, 4});
  });

  test('shuffle keeps the current item first', () {
    final order = _orderOf([0, 1, 2, 3, 4]);
    order.shuffle(initialIndex: 3);
    expect(order.indices.first, 3);
    expect(order.indices.toSet(), {0, 1, 2, 3, 4});
  });
}
