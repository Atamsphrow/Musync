// Apparence › Thème: which brightness the app renders at, and the active
// lyric line staying readable on both.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';
import 'package:musync/features/settings/providers/lyrics_appearance_provider.dart';

void main() {
  test('the preference wins over the system, except for « Système »', () {
    expect(
      effectiveBrightness(AppThemePreference.dark, Brightness.light),
      Brightness.dark,
    );
    expect(
      effectiveBrightness(AppThemePreference.light, Brightness.dark),
      Brightness.light,
    );
    expect(
      effectiveBrightness(AppThemePreference.system, Brightness.light),
      Brightness.light,
    );
    expect(
      effectiveBrightness(AppThemePreference.system, Brightness.dark),
      Brightness.dark,
    );
  });

  Future<Color> activeColorUnder(
    WidgetTester tester,
    Brightness brightness,
  ) async {
    late Color color;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: brightness,
          ),
        ),
        home: Builder(
          builder: (context) {
            color = lyricsActiveColor(context, const LyricsAppearance());
            return const SizedBox();
          },
        ),
      ),
    );
    return color;
  }

  testWidgets('neutral active line: white when dark, never white when light',
      (tester) async {
    expect(await activeColorUnder(tester, Brightness.dark), Colors.white);
    expect(
      await activeColorUnder(tester, Brightness.light),
      isNot(Colors.white),
    );
  });
}
