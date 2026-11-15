import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/ui/widgets/karaoke_animated_line.dart';
import 'package:musync/features/player/ui/widgets/karaoke_separators.dart';
import 'package:musync/features/player/ui/widgets/synced_lyrics_view.dart';

LyricWord _mot(String text, int startMs, int durMs, {bool bg = false}) =>
    LyricWord(
      start: Duration(milliseconds: startMs),
      duration: Duration(milliseconds: durMs),
      text: text,
      isBackground: bg,
    );

/// « Percocet » : Per 1000–1200, co 1200–1400, cet 1400–1700.
LyricLine _percocet() => LyricLine(
  timestamp: const Duration(milliseconds: 1000),
  text: 'Percocet',
  words: [_mot('Per', 1000, 200), _mot('co', 1200, 200), _mot('cet', 1400, 300)],
);

/// Ligne normale : un fragment par mot.
LyricLine _normale() => LyricLine(
  timestamp: const Duration(milliseconds: 1000),
  text: 'Hello big world',
  words: [
    _mot('Hello', 1000, 400),
    _mot('big', 1500, 300),
    _mot('world', 1900, 400),
  ],
);

const _sung = TextStyle(color: Colors.white, fontWeight: FontWeight.w700);
final _unsung = TextStyle(
  color: Colors.white.withValues(alpha: 0.55),
  fontWeight: FontWeight.w400,
);

String _texte(List<InlineSpan> spans) =>
    spans.whereType<TextSpan>().map((s) => s.text ?? '').join();

Widget _contenu(WidgetSpan span) {
  Widget w = (span.child as GestureDetector).child!;
  if (w is Transform) w = w.child!;
  return w;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('karaokeWordUnits', () {
    test('« Per co cet » collé forme une seule unité', () {
      final units = karaokeWordUnits(_percocet());
      expect(units, hasLength(1));
      expect(units.single.text, 'Percocet');
      expect(units.single.firstIndex, 0);
      expect(units.single.lastIndex, 2);
      expect(units.single.start, const Duration(milliseconds: 1000));
      expect(units.single.end, const Duration(milliseconds: 1700));
    });

    test('ligne normale : une unité par fragment', () {
      final units = karaokeWordUnits(_normale());
      expect(units.map((u) => u.text), ['Hello', 'big', 'world']);
      expect(units.map((u) => u.separatorBefore), ['', ' ', ' ']);
    });

    test('une unité ne mélange jamais voix principale et chœur', () {
      final line = LyricLine(
        timestamp: Duration.zero,
        text: 'Peroh',
        words: [_mot('Per', 0, 200), _mot('oh', 200, 200, bg: true)],
      );
      final units = karaokeWordUnits(line);
      expect(units, hasLength(2));
      expect(units[1].separatorBefore, '');
      expect(units[1].isBackground, isTrue);
    });

    test('mots incohérents avec le texte : un fragment par unité', () {
      final line = LyricLine(
        timestamp: Duration.zero,
        text: 'autre chose',
        words: [_mot('Per', 0, 200), _mot('co', 200, 200)],
      );
      expect(karaokeWordUnits(line), hasLength(2));
    });
  });

  group('karaokeWordSpans (statique)', () {
    test('« Percocet » est rendu collé, sans espace entre fragments', () {
      final spans = karaokeWordSpans(
        line: _percocet(),
        wordIndex: -1,
        sungStyle: _sung,
        unsungStyle: _unsung,
      );
      expect(spans, hasLength(1));
      expect(_texte(spans), 'Percocet');
    });

    test('l\'unité entière est chantée dès que le premier fragment est atteint',
        () {
      final spans = karaokeWordSpans(
        line: _percocet(),
        wordIndex: 0,
        sungStyle: _sung,
        unsungStyle: _unsung,
      );
      expect(spans.single.style, _sung);
    });

    test('aucun fragment atteint : toute l\'unité est non chantée', () {
      final spans = karaokeWordSpans(
        line: _percocet(),
        wordIndex: -1,
        sungStyle: _sung,
        unsungStyle: _unsung,
      );
      expect(spans.single.style, _unsung);
    });

    test('tap sur « cet » : seek au début de « Per »', () {
      Duration? cherche;
      final spans = karaokeWordSpans(
        line: _percocet(),
        wordIndex: -1,
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (p) => cherche = p,
      );
      (spans.single.recognizer! as TapGestureRecognizer).onTap!();
      expect(cherche, const Duration(milliseconds: 1000));
    });

    test('ligne normale : rendu inchangé (mots + espaces, styles par mot)', () {
      final spans = karaokeWordSpans(
        line: _normale(),
        wordIndex: 1,
        sungStyle: _sung,
        unsungStyle: _unsung,
      );
      expect(spans.map((s) => s.text), ['Hello', ' ', 'big', ' ', 'world']);
      // L'espace prend le style du mot précédent (comportement d'avant) :
      // l'espace après « big » (chanté) est chanté, « world » ne l'est pas.
      expect(spans.map((s) => s.style), [_sung, _sung, _sung, _sung, _unsung]);
    });

    test('ligne normale : tap sur un mot et sur un espace', () {
      final cherches = <Duration>[];
      final spans = karaokeWordSpans(
        line: _normale(),
        wordIndex: -1,
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: cherches.add,
      );
      (spans[2].recognizer! as TapGestureRecognizer).onTap!(); // big
      (spans[1].recognizer! as TapGestureRecognizer).onTap!(); // espace
      expect(cherches, [
        const Duration(milliseconds: 1500),
        const Duration(milliseconds: 1000),
      ]);
    });

    test('unité au milieu d\'une ligne : séparateurs d\'unité conservés', () {
      final line = LyricLine(
        timestamp: Duration.zero,
        text: 'a Percocet b',
        words: [
          _mot('a', 0, 100),
          _mot('Per', 200, 200),
          _mot('co', 400, 200),
          _mot('cet', 600, 200),
          _mot('b', 900, 100),
        ],
      );
      final spans = karaokeWordSpans(
        line: line,
        wordIndex: 2, // « co » : l'unité entière est déjà chantée
        sungStyle: _sung,
        unsungStyle: _unsung,
      );
      expect(spans.map((s) => s.text), ['a', ' ', 'Percocet', ' ', 'b']);
      expect(spans.map((s) => s.style), [_sung, _sung, _sung, _sung, _unsung]);
    });
  });

  group('animatedKaraokeSpans (balayage)', () {
    test('l\'unité courante ne produit qu\'UN WidgetSpan', () {
      final spans = animatedKaraokeSpans(
        line: _percocet(),
        wordIndex: 1, // « co » : milieu de l'unité
        position: const Duration(milliseconds: 1300),
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      expect(spans, hasLength(1));
      expect(spans.single, isA<WidgetSpan>());
    });

    test('le soulèvement s\'applique à l\'unité entière, une seule fois', () {
      final spans = animatedKaraokeSpans(
        line: _percocet(),
        wordIndex: 0,
        position: const Duration(milliseconds: 1350),
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      final child = (spans.single as WidgetSpan).child as GestureDetector;
      expect(child.child, isA<Transform>());
    });

    test('le balayage remplit l\'unité du début du premier fragment à la fin '
        'du dernier', () {
      final spans = animatedKaraokeSpans(
        line: _percocet(),
        wordIndex: 1,
        position: const Duration(milliseconds: 1350), // mi-unité (1000–1700)
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      final stack = (_contenu(spans.single as WidgetSpan) as SizedBox).child!
          as Stack;
      final clip = stack.children[1] as ClipRect;
      final align = clip.child! as Align;
      expect(align.widthFactor, closeTo(0.5, 0.001));
      final texte = ((align.child! as SizedBox).child! as Text).data;
      expect(texte, 'Percocet');
    });

    test('tap sur le mot animé : seek au début de l\'unité', () {
      Duration? cherche;
      final spans = animatedKaraokeSpans(
        line: _percocet(),
        wordIndex: 2,
        position: const Duration(milliseconds: 1500),
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (p) => cherche = p,
      );
      ((spans.single as WidgetSpan).child as GestureDetector).onTap!();
      expect(cherche, const Duration(milliseconds: 1000));
    });

    test('unité hors mouvement : un seul TextSpan collé', () {
      final spans = animatedKaraokeSpans(
        line: _percocet(),
        wordIndex: -1,
        position: Duration.zero,
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      expect(spans, hasLength(1));
      expect(spans.single, isA<TextSpan>());
      expect((spans.single as TextSpan).text, 'Percocet');
    });

    test('ligne normale : un WidgetSpan pour le mot courant, le reste en '
        'TextSpan', () {
      final spans = animatedKaraokeSpans(
        line: _normale(),
        wordIndex: 0,
        position: const Duration(milliseconds: 1200),
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      expect(spans, hasLength(5));
      expect(spans[0], isA<WidgetSpan>());
      expect(spans.skip(1).every((s) => s is TextSpan), isTrue);
      expect(_texte(spans), ' big world');
    });

    test('unité de plus de 7 lettres : jamais de WidgetSpan par fragment', () {
      final line = LyricLine(
        timestamp: Duration.zero,
        text: 'Philadelphia',
        words: [
          _mot('Phil', 0, 3000),
          _mot('a', 3000, 3000),
          _mot('del', 6000, 3000),
          _mot('phia', 9000, 3000),
        ],
      );
      final spans = animatedKaraokeSpans(
        line: line,
        wordIndex: 1,
        position: const Duration(milliseconds: 4000),
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      expect(spans.whereType<WidgetSpan>(), hasLength(1));
    });
  });
}
