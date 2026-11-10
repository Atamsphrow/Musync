// Widget test: the sync editor line menu's "Décaler à partir d'ici" row.
//
// The provider logic (nudgeFrom) already had unit tests; what was missing was
// the wiring — the row existed nowhere in the menu. This pumps the tile alone
// (the lyric_line_tile_test.dart pattern) and asserts the menu emits the new
// actions, so the enum, the row and the handler's input are all covered. The
// effect itself stays with the nudgeFrom unit tests in sync_editor_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/sync_editor/ui/widgets/lyric_line_tile.dart';

void main() {
  testWidgets(
    'menu "Décaler à partir d\'ici" emits nudgeFrom actions, both ways',
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

      expect(find.text("Décaler à partir d'ici"), findsOneWidget);
      expect(
        find.byTooltip('Reculer cette ligne et les suivantes de 100 ms'),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Avancer cette ligne et les suivantes de 100 ms'),
        findsOneWidget,
      );

      // The row does not dismiss the menu: both directions work in a row.
      await tester.tap(
        find.byTooltip('Reculer cette ligne et les suivantes de 100 ms'),
      );
      await tester.pump();
      await tester.tap(
        find.byTooltip('Avancer cette ligne et les suivantes de 100 ms'),
      );
      await tester.pump();
      expect(
        actions,
        const [
          LyricLineAction.nudgeFromBack,
          LyricLineAction.nudgeFromForward,
        ],
      );

      // The line's own nudge is still there, on its own row.
      await tester.tap(find.byTooltip('Reculer de 100 ms'));
      await tester.pump();
      expect(actions.last, LyricLineAction.nudgeBack);
    },
  );
}
