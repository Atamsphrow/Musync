// Menu de la ligne (éditeur de synchro) : écouter depuis la ligne et
// ouvrir la fenêtre filtrée à partir d'elle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/sync_editor/ui/widgets/lyric_line_tile.dart';

Widget _tile(LyricLine line, void Function(LyricLineAction) onAction) =>
    MaterialApp(
      home: Scaffold(
        body: LyricLineTile(
          line: line,
          isPlaying: false,
          isCursor: false,
          showTimestamp: true,
          onStamp: () {},
          onSelect: () {},
          onAction: onAction,
          onEditTimestamp: () {},
        ),
      ),
    );

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
}

Finder _menuItem(LyricLineAction action) => find.byWidgetPredicate(
  (w) =>
      w is PopupMenuItem<LyricLineAction> && w.value == action,
);

void main() {
  testWidgets('le menu propose écouter et synchroniser à partir d\'ici', (
    tester,
  ) async {
    await tester.pumpWidget(
      _tile(
        const LyricLine(
          timestamp: Duration(milliseconds: 1500),
          text: 'Une',
        ),
        (_) {},
      ),
    );
    await _openMenu(tester);
    expect(find.text('Écouter à partir d\'ici'), findsOneWidget);
    expect(find.text('Synchroniser à partir d\'ici'), findsOneWidget);
    expect(
      tester.widget<PopupMenuItem<LyricLineAction>>(
        _menuItem(LyricLineAction.playFromHere),
      ).enabled,
      isTrue,
    );
  });

  testWidgets('écouter envoie playFromHere', (tester) async {
    LyricLineAction? tapped;
    await tester.pumpWidget(
      _tile(
        const LyricLine(
          timestamp: Duration(milliseconds: 1500),
          text: 'Une',
        ),
        (a) => tapped = a,
      ),
    );
    await _openMenu(tester);
    await tester.tap(find.text('Écouter à partir d\'ici'));
    await tester.pumpAndSettle();
    expect(tapped, LyricLineAction.playFromHere);
  });

  testWidgets('synchroniser envoie syncFromHere', (tester) async {
    LyricLineAction? tapped;
    await tester.pumpWidget(
      _tile(
        const LyricLine(
          timestamp: Duration(milliseconds: 1500),
          text: 'Une',
        ),
        (a) => tapped = a,
      ),
    );
    await _openMenu(tester);
    await tester.tap(find.text('Synchroniser à partir d\'ici'));
    await tester.pumpAndSettle();
    expect(tapped, LyricLineAction.syncFromHere);
  });

  testWidgets('écouter est désactivé sans horodatage', (tester) async {
    await tester.pumpWidget(
      _tile(const LyricLine(timestamp: null, text: '[Refrain]'), (_) {}),
    );
    await _openMenu(tester);
    expect(
      tester.widget<PopupMenuItem<LyricLineAction>>(
        _menuItem(LyricLineAction.playFromHere),
      ).enabled,
      isFalse,
    );
    // La fenêtre filtrée, elle, ne dépend pas de l'horodatage.
    expect(
      tester.widget<PopupMenuItem<LyricLineAction>>(
        _menuItem(LyricLineAction.syncFromHere),
      ).enabled,
      isTrue,
    );
  });
}
