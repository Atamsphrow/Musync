import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';

void main() {
  group('LyricsAppearance', () {
    test('defaults match the Musicolet look', () {
      const a = LyricsAppearance();
      expect(a.fontSize, LyricsFontSize.medium);
      expect(a.textAlign, LyricsTextAlign.center);
      expect(a.fontStyle, LyricsFontStyle.stylized);
      expect(a.italic, isTrue);
      expect(a.colorMode, LyricsColorMode.white);
      expect(a.bubbleColorMode, LyricsColorMode.white);
      expect(a.fontScale, 1.0);
    });

    test('fontScale follows the size', () {
      expect(
        const LyricsAppearance(fontSize: LyricsFontSize.small).fontScale,
        0.85,
      );
      expect(
        const LyricsAppearance(fontSize: LyricsFontSize.large).fontScale,
        1.2,
      );
    });

    test('round-trips through JSON', () {
      const a = LyricsAppearance(
        fontSize: LyricsFontSize.large,
        textAlign: LyricsTextAlign.left,
        fontStyle: LyricsFontStyle.normal,
        italic: false,
        colorMode: LyricsColorMode.materialYou,
        bubbleColorMode: LyricsColorMode.materialYou,
      );
      final b = LyricsAppearance.fromJson(a.toJson());
      expect(b.fontSize, a.fontSize);
      expect(b.textAlign, a.textAlign);
      expect(b.fontStyle, a.fontStyle);
      expect(b.italic, a.italic);
      expect(b.colorMode, a.colorMode);
      expect(b.bubbleColorMode, a.bubbleColorMode);
    });

    test('bad JSON falls back to defaults, never throws', () {
      final a = LyricsAppearance.fromJson({
        'fontSize': 'huge',
        'italic': 'yes',
      });
      expect(a.fontSize, LyricsFontSize.medium);
      expect(a.italic, isTrue);
      expect(LyricsAppearance.fromJson(null), const LyricsAppearance());
      expect(LyricsAppearance.fromJson('nope'), const LyricsAppearance());
    });

    test('bubble color is independent from the player color', () {
      const a = LyricsAppearance(
        colorMode: LyricsColorMode.white,
        bubbleColorMode: LyricsColorMode.materialYou,
      );
      expect(a.colorMode, isNot(a.bubbleColorMode));
    });
  });

  group('LyricsAppearanceStore', () {
    test('save then load round-trips', () async {
      final dir = await Directory.systemTemp.createTemp('appearance_');
      try {
        final s = LyricsAppearanceStore(root: dir);
        const a = LyricsAppearance(
          fontSize: LyricsFontSize.small,
          italic: false,
        );
        await s.save(a);
        final b = await s.load();
        expect(b.fontSize, LyricsFontSize.small);
        expect(b.italic, isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('missing file gives defaults', () async {
      final dir = await Directory.systemTemp.createTemp('appearance_');
      try {
        final s = LyricsAppearanceStore(root: dir);
        expect(await s.load(), const LyricsAppearance());
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
