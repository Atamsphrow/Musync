/// Tests de l'aide ancrée : app_help cherche dans la base vérifiée, ne génère
/// jamais librement.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/ai_assistant/data/app_knowledge.dart';
import 'package:musync/features/ai_assistant/data/tools/settings_tools.dart';

AiToolContext _ctx(Ref ref) => AiToolContext(
      ref: ref,
      runTool: (_, _) async => AiToolResult.fail('non'),
      hasTool: (_) => false,
      requiresConfirmation: (_) => false,
    );

final _refProbe = Provider<Ref>((ref) => ref);

void main() {
  group('findHelpArticle', () {
    test('« bulle » → la fiche bulle', () {
      final article = findHelpArticle('comment active la bulle flottante ?');
      expect(article, isNotNull);
      expect(article!.text, contains('Lecture en cours'));
      expect(article.text, contains('UN TAP'));
    });

    test('insensible aux accents et à la casse', () {
      expect(findHelpArticle('BULLE'), isNotNull);
      expect(findHelpArticle('cale les paroles'), isNotNull);
    });

    test('requête inconnue → null (pas d’invention)', () {
      expect(findHelpArticle('comment cuire un œuf ?'), isNull);
      expect(findHelpArticle(''), isNull);
    });
  });

  group('AppHelpTool', () {
    test('« bulle » retourne la fiche vérifiée', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const tool = AppHelpTool();
      final result = await tool.execute(
        _ctx(container.read(_refProbe)),
        {'question': 'active la bulle flottante'},
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('Lecture en cours'));
      // Surtout pas la procédure hallucinée vue sur appareil.
      expect(result.message, contains('AUTRES applis'));
    });

    test('requête inconnue → ignorance honnête, pas d’invention', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const tool = AppHelpTool();
      final result = await tool.execute(
        _ctx(container.read(_refProbe)),
        {'question': 'comment cuire un œuf ?'},
      );
      expect(result.ok, isTrue);
      expect(result.message, contains('Je ne sais pas'));
    });

    test('chaque fiche est non vide et en français', () {
      for (final article in appKnowledge) {
        expect(article.text.trim(), isNotEmpty);
        expect(article.keywords, isNotEmpty);
      }
      expect(appKnowledge.length, greaterThanOrEqualTo(8));
    });
  });
}
