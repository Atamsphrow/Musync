// The ≡ handle of the queue: its direction decides. A swipe to the right
// removes the row — even in a natural arc that drifts down past the touch
// slop, which used to let the vertical reorder recognizer lift the row into
// a drag proxy mid-slide. A straight vertical drag still reorders.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/player/data/audio_player_service.dart';
import 'package:musync/features/player/providers/named_queue_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/ui/queue_screen.dart';

Song _song(int id) => Song(
      id: id,
      title: 'Titre $id',
      artist: 'Artiste',
      album: 'Album',
      duration: 180000,
      filePath: '/music/$id.mp3',
    );

class _FakePlayer extends AudioPlayerService {
  List<Song> songs = [for (var i = 0; i < 6; i++) _song(i)];
  final reorders = <(int, int)>[];
  final removals = <int>[];

  @override
  List<Song> get queue => songs;

  @override
  int get currentIndex => 3;

  @override
  Song? get currentSong => songs[3];

  @override
  Stream<int?> get currentIndexStream => const Stream.empty();

  @override
  Stream<Song?> get currentSongStream => const Stream.empty();

  @override
  (int, int)? reorderQueueSync(int oldIndex, int newIndex) {
    reorders.add((oldIndex, newIndex));
    final updated = List.of(songs);
    updated.insert(newIndex, updated.removeAt(oldIndex));
    songs = updated;
    return (oldIndex, newIndex);
  }

  @override
  Future<void> reorderQueueApply(int oldIndex, int newIndex) async {}

  @override
  Future<void> removeFromQueue(int index) async {
    removals.add(index);
    songs = List.of(songs)..removeAt(index);
  }
}

class _QuietNamedQueues extends NamedQueuesController {
  @override
  NamedQueuesState build() => const NamedQueuesState();

  @override
  Future<void> syncActiveFromPlayer() async {}
}

Future<_FakePlayer> _pump(WidgetTester tester) async {
  final player = _FakePlayer();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        audioPlayerServiceProvider.overrideWithValue(player),
        namedQueuesProvider.overrideWith(_QuietNamedQueues.new),
      ],
      child: const MaterialApp(home: Scaffold(body: QueueListBody())),
    ),
  );
  await tester.pumpAndSettle();
  return player;
}

void main() {
  testWidgets('a right swipe with a downward arc removes, never reorders',
      (tester) async {
    final player = await _pump(tester);
    final handle = find.byIcon(Icons.drag_handle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    // 150 px right and 25 px down, in small steps like a real finger.
    for (var i = 0; i < 15; i++) {
      await gesture.moveBy(const Offset(10, 25 / 15));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Not lifted: a reorder replaces the row in the list by an empty slot
    // and draws it in the overlay instead.
    expect(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.text('Titre 0'),
      ),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(player.reorders, isEmpty);
    expect(player.removals, [0]);
  });

  testWidgets('a vertical drag on the handle still reorders', (tester) async {
    final player = await _pump(tester);
    final handle = find.byIcon(Icons.drag_handle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Lifted: the slot in the list is empty while the drag runs.
    expect(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.text('Titre 0'),
      ),
      findsNothing,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(player.removals, isEmpty);
    expect(player.reorders, isNotEmpty);
    expect(player.reorders.single.$1, 0);
  });

  testWidgets('TalkBack can move and remove a row without dragging',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final player = await _pump(tester);

    void perform(String rowTitle, String action) {
      final id = CustomSemanticsAction.getIdentifier(
        CustomSemanticsAction(label: action),
      );
      var node = tester.getSemantics(find.text(rowTitle));
      while (!node.getSemanticsData().customSemanticsActionIds!.contains(id)) {
        node = node.parent!;
      }
      node.owner!.performAction(node.id, SemanticsAction.customAction, id);
    }

    perform('Titre 0', 'Descendre');
    await tester.pumpAndSettle();
    expect(player.reorders, [(0, 1)]);

    perform('Titre 2', 'Retirer de la file');
    await tester.pumpAndSettle();
    expect(player.removals, [2]);
    semantics.dispose();
  });
}
