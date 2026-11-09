// H91 : Duration.zero est un vrai temps (00:00.00), pas « en attente ».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/sync_editor/ui/widgets/lyric_line_tile.dart';

Widget _tile(LyricLine line) => MaterialApp(
  home: Scaffold(
    body: LyricLineTile(
      line: line,
      isPlaying: false,
      isCursor: false,
      showTimestamp: true,
      onStamp: () {},
      onSelect: () {},
      onAction: (_) {},
      onEditTimestamp: () {},
    ),
  ),
);

void main() {
  testWidgets('une ligne calée à 0 ms affiche 00:00.00, pas --:--.--', (
    tester,
  ) async {
    await tester.pumpWidget(
      _tile(const LyricLine(timestamp: Duration.zero, text: 'Intro')),
    );
    expect(find.text('00:00.00'), findsOneWidget);
    expect(find.text('--:--.--'), findsNothing);
  });

  testWidgets('une ligne sans horodatage affiche —  —', (tester) async {
    await tester.pumpWidget(
      _tile(const LyricLine(timestamp: null, text: '[Refrain]')),
    );
    expect(find.text('—  —'), findsOneWidget);
  });

  testWidgets('une ligne calée à 1,5 s affiche son temps', (tester) async {
    await tester.pumpWidget(
      _tile(
        const LyricLine(timestamp: Duration(milliseconds: 1500), text: 'Une'),
      ),
    );
    expect(find.text('00:01.50'), findsOneWidget);
  });
}
