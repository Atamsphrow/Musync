import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/ui/widgets/karaoke_animated_line.dart';

LyricWord _mot(String text, int startMs, int durMs) => LyricWord(
  start: Duration(milliseconds: startMs),
  duration: Duration(milliseconds: durMs),
  text: text,
);

/// « BUT I CAN'T CHANGE YOU » : CHANGE est le mot courant (1000–1600).
LyricLine _ligne() => LyricLine(
  timestamp: const Duration(milliseconds: 0),
  text: "CAN'T CHANGE YOU",
  words: [_mot("CAN'T", 0, 400), _mot('CHANGE', 1000, 600), _mot('YOU', 1700, 400)],
);

const _sung = TextStyle(color: Colors.white, fontWeight: FontWeight.w700);
final _dimColor = Colors.white.withValues(alpha: 0.55);
final _unsung = TextStyle(color: _dimColor, fontWeight: FontWeight.w400);

/// Les deux copies du mot courant : [0] celle du dessous (ton de base),
/// [1] la lumineuse clippée.
({Text dessous, Text lumineuse}) _copies(List<InlineSpan> spans, int at) {
  Widget w = ((spans[at] as WidgetSpan).child as GestureDetector).child!;
  if (w is Transform) w = w.child!;
  final stack = (w as SizedBox).child! as Stack;
  final clip = stack.children[1] as ClipRect;
  final lumineuse = ((clip.child! as Align).child! as SizedBox).child! as Text;
  return (dessous: stack.children[0] as Text, lumineuse: lumineuse);
}

List<InlineSpan> _rendre(int positionMs) => animatedKaraokeSpans(
  line: _ligne(),
  wordIndex: 1,
  position: Duration(milliseconds: positionMs),
  sungStyle: _sung,
  unsungStyle: _unsung,
  onWordTap: (_) {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sweepBaseStyle', () {
    test('le ton de base est plus lumineux que le dim complet', () {
      final base = sweepBaseStyle(_sung, _unsung);
      expect(base.color!.a, greaterThan(_dimColor.a));
      expect(base.color, isNot(_dimColor));
    });

    test('le ton de base reste en dessous de la couleur chantée', () {
      final base = sweepBaseStyle(_sung, _unsung);
      expect(base.color!.a, lessThanOrEqualTo(_sung.color!.a));
    });

    test('la graisse du mot chanté est conservée', () {
      expect(sweepBaseStyle(_sung, _unsung).fontWeight, FontWeight.w700);
    });
  });

  group('mot courant en balayage', () {
    test('début de mot (fraction ~0) : pas le style des mots non chantés', () {
      final copies = _copies(_rendre(1000), 2);
      final style = copies.dessous.style!;
      expect(style.color, isNot(_dimColor));
      expect(style.color!.a, greaterThan(_dimColor.a));
    });

    test('mi-mot : pas le style des mots non chantés', () {
      final copies = _copies(_rendre(1300), 2);
      final style = copies.dessous.style!;
      expect(style.color!.a, greaterThan(_dimColor.a));
    });

    test('la partie balayée reste la plus lumineuse', () {
      for (final ms in [1000, 1300, 1550]) {
        final copies = _copies(_rendre(ms), 2);
        expect(
          copies.lumineuse.style!.color!.a,
          greaterThanOrEqualTo(copies.dessous.style!.color!.a),
        );
        expect(copies.lumineuse.style, _sung);
      }
    });

    test('le mot courant n\'est jamais plus terne qu\'un mot non chanté, '
        'à aucun moment du mot', () {
      for (var ms = 1000; ms <= 1600; ms += 50) {
        final copies = _copies(_rendre(ms), 2);
        expect(
          copies.dessous.style!.color!.a,
          greaterThan(_unsung.color!.a),
          reason: 'à $ms ms',
        );
      }
    });

    test('unité collée : le ton intermédiaire couvre toute l\'unité', () {
      final line = LyricLine(
        timestamp: Duration.zero,
        text: 'Percocet',
        words: [_mot('Per', 1000, 200), _mot('co', 1200, 200), _mot('cet', 1400, 300)],
      );
      final spans = animatedKaraokeSpans(
        line: line,
        wordIndex: 0,
        position: const Duration(milliseconds: 1000),
        sungStyle: _sung,
        unsungStyle: _unsung,
        onWordTap: (_) {},
      );
      expect(spans, hasLength(1));
      final copies = _copies(spans, 0);
      expect(copies.dessous.data, 'Percocet');
      expect(copies.dessous.style!.color!.a, greaterThan(_dimColor.a));
    });

    test('les mots non chantés gardent le dim complet', () {
      final spans = _rendre(1300);
      final apres = spans.last as TextSpan; // YOU
      expect(apres.style!.color, _dimColor);
    });
  });
}
