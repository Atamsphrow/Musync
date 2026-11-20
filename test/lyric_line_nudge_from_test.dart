// Widget test: the sync editor line menu keeps one ±100 ms row (this line
// only). « Décaler à partir d'ici » was removed at the user's request —
// « Caler ici et décaler tout » covers a track that drifts from a point.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/sync_editor/ui/widgets/lyric_line_tile.dart';

void main() {
  testWidgets('the line menu has the line nudge, not « Décaler à partir d’ici »',
      (tester) async {
    final actions = <LyricLineAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricLineTile(
            line: const LyricLine(
              timestamp: Duration(seconds: 20),
              text: 'Deux',
            ),
            isPlaying: false,
            isCursor: false,
            showTimestamp: true,
            onStamp: () {},
            onSelect: () {},
            onAction: actions.add,
            onEditTimestamp: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text("Décaler à partir d'ici"), findsNothing);
    expect(find.byTooltip('Reculer de 100 ms'), findsOneWidget);
    expect(find.byTooltip('Avancer de 100 ms'), findsOneWidget);

    // The row does not dismiss the menu: both directions work in a row.
    await tester.tap(find.byTooltip('Reculer de 100 ms'));
    await tester.pump();
    await tester.tap(find.byTooltip('Avancer de 100 ms'));
    await tester.pump();
    expect(actions, [LyricLineAction.nudgeBack, LyricLineAction.nudgeForward]);
  });
}
