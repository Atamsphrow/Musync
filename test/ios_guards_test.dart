/// Gardes iOS : ce qui n'existe pas sur iPhone doit être annoncé comme tel
/// (outils IA) ou masqué (UI), jamais laissé planter ou semblant marcher.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/ai_tool_registry.dart';
import 'package:musync/features/library/data/music_scanner.dart';

void main() {
  group('ids stables iOS', () {
    test('même chemin → même id', () {
      expect(
        MusicScanner.stableIdForPath('/docs/a.mp3'),
        MusicScanner.stableIdForPath('/docs/a.mp3'),
      );
    });

    test('chemins différents → ids différents', () {
      expect(
        MusicScanner.stableIdForPath('/docs/a.mp3'),
        isNot(MusicScanner.stableIdForPath('/docs/b.mp3')),
      );
    });

    test('valeur connue (déterminisme inter-lancements)', () {
      // FNV-1a 32 bits : si l'algorithme change, ce test casse et c'est
      // voulu — les ids doivent rester stables d'un lancement à l'autre.
      expect(MusicScanner.stableIdForPath('/docs/a.mp3'), 0x445f4041);
    });
  });

  group('outils indisponibles sur iOS annoncés dans leur description', () {
    test('les 4 outils Android-only le disent', () {
      final registry = buildAiToolRegistry();
      for (final name in [
        'schedule_once',
        'schedule_daily',
        'set_headphone_trigger',
        'toggle_bubble',
      ]) {
        final tool = registry[name];
        expect(tool, isNotNull, reason: 'outil manquant : $name');
        expect(
          tool!.description,
          contains('Android uniquement'),
          reason: '$name doit annoncer sa limite iOS',
        );
      }
    });
  });
}
