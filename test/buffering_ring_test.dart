// The buffering ring is drawn over the play button, never laid out with it:
// in the mini player the ring (32 dp) is wider than the icon (24 dp), and as
// a plain Stack child it grew the IconButton's own surface from 40 to 48 dp
// when it appeared — and, without the 48 dp tap-target padding (desktop,
// shrink-wrapped themes), the title beside it jumped, then jumped back.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/ui/widgets/player_controls.dart';

final _buffering = StateProvider<bool>((ref) => false);

void main() {
  testWidgets('the ring appearing does not resize the button', (tester) async {
    final container = ProviderContainer(
      overrides: [
        isBufferingProvider.overrideWith((ref) => ref.watch(_buffering)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: () {},
                    icon: const BufferingRing(
                      diameter: 32,
                      color: Colors.blue,
                      child: Icon(Icons.play_arrow),
                    ),
                  ),
                  const Text('Titre'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final surface = find.descendant(
      of: find.byType(IconButton),
      matching: find.byType(InkWell),
    );
    final buttonBefore = tester.getSize(find.byType(IconButton));
    final surfaceBefore = tester.getSize(surface);
    final titleBefore = tester.getTopLeft(find.text('Titre'));

    container.read(_buffering.notifier).state = true;
    await tester.pump(); // The provider rebuilds; the delay starts.
    await tester.pump(const Duration(milliseconds: 400)); // Past the delay.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.getSize(find.byType(CircularProgressIndicator)),
      const Size.square(32),
    );
    expect(tester.getSize(find.byType(IconButton)), buttonBefore);
    expect(tester.getSize(surface), surfaceBefore);
    expect(tester.getTopLeft(find.text('Titre')), titleBefore);

    container.read(_buffering.notifier).state = false;
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
