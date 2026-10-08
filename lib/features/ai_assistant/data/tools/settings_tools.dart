/// Outils de réglages et d'aide : apparence des paroles, questions sur l'app.
library;

import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:flutter/services.dart';
import 'package:musync/features/ai_assistant/data/app_knowledge.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';
import 'package:musync/features/bubble/providers/bubble_provider.dart';
import 'package:musync/features/settings/providers/lyrics_appearance_provider.dart';

/// Règle l'apparence des paroles (les mêmes réglages que l'onglet Apparences).
class SetAppearanceTool extends AiTool {
  const SetAppearanceTool();

  @override
  String get name => 'set_appearance';

  @override
  String get description =>
      'Change l’apparence des paroles : italique, taille, alignement, '
      'style de police. Les mêmes réglages que l’onglet Apparences.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'italic': 'booléen, optionnel — texte en italique',
          'font_size':
              'string, optionnel — "petite", "moyenne" ou "grande"',
          'align': 'string, optionnel — "gauche", "centre" ou "droite"',
          'style': 'string, optionnel — "sobre" ou "stylisée" (serif)',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Modifier l’apparence des paroles.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    // D'abord valider les arguments, avant de toucher aux providers.
    final italic = args['italic'];
    if (italic != null && italic is! bool) {
      throw const AiToolArgError('Argument « italic » : vrai/faux attendu.');
    }

    LyricsFontSize? fontSize;
    final size = optString(args, 'font_size');
    if (size != null) {
      fontSize = switch (size.toLowerCase()) {
        'petite' => LyricsFontSize.small,
        'moyenne' => LyricsFontSize.medium,
        'grande' => LyricsFontSize.large,
        _ => throw const AiToolArgError(
            'font_size doit être petite, moyenne ou grande.',
          ),
      };
    }

    LyricsTextAlign? textAlign;
    final align = optString(args, 'align');
    if (align != null) {
      textAlign = switch (align.toLowerCase()) {
        'gauche' => LyricsTextAlign.left,
        'centre' || 'centré' || 'centree' => LyricsTextAlign.center,
        'droite' => LyricsTextAlign.right,
        _ => throw const AiToolArgError(
            'align doit être gauche, centre ou droite.',
          ),
      };
    }

    LyricsFontStyle? fontStyle;
    final style = optString(args, 'style');
    if (style != null) {
      fontStyle = switch (style.toLowerCase()) {
        'sobre' => LyricsFontStyle.normal,
        'stylisée' || 'stylisee' => LyricsFontStyle.stylized,
        _ => throw const AiToolArgError(
            'style doit être sobre ou stylisée.',
          ),
      };
    }

    final notifier = ctx.ref.read(lyricsAppearanceProvider.notifier);
    final next = ctx.ref.read(lyricsAppearanceProvider).copyWith(
          italic: italic as bool?,
          fontSize: fontSize,
          textAlign: textAlign,
          fontStyle: fontStyle,
        );
    await notifier.update(next);
    return AiToolResult.ok('Apparence des paroles mise à jour.');
  }
}

/// Répond aux questions sur l'app elle-même.
///
/// L'outil rend un aide-mémoire ; c'est le LLM qui formule la réponse à
/// l'utilisateur à partir de « answer ».
/// Aide sur Musync, ANCRÉE et jamais générée librement.
///
/// Cherche par mots-clés dans la base de connaissances vérifiée
/// ([appKnowledge]) et retourne la fiche telle quelle. Si rien ne matche, la
/// réponse honnête « je ne sais pas » — inventer une procédure (sections de
/// réglages imaginaires…) est exactement ce qu'on a déjà vu sur appareil.
class AppHelpTool extends AiTool {
  const AppHelpTool();

  @override
  String get name => 'app_help';

  @override
  String get description =>
      'Aide sur Musync : cherche dans la base de connaissances vérifiée '
      '(bulle, calage des paroles, pull-to-refresh, sources, files nommées, '
      'minuteur, Journal, exclusions, commandes !). « question » : la question '
      'posée. À appeler pour TOUTE question sur l’app — ne jamais répondre '
      'de tête.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'question': 'string, requis — la question posée, en entier',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Chercher dans l’aide vérifiée.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final question = reqString(args, 'question');
    final article = findHelpArticle(question);
    if (article == null) {
      return AiToolResult.ok(
        'Je ne sais pas faire ça dans Musync — reformule ou demande autre '
        'chose.',
      );
    }
    return AiToolResult.ok(article.text);
  }
}

/// Ferme l'application.
///
/// Non destructif et réversible (un tap la relance) : pas de confirmation.
/// Demandé explicitement par l'utilisateur après un premier refus de l'IA.
class CloseAppTool extends AiTool {
  const CloseAppTool();

  @override
  String get name => 'close_app';

  @override
  String get description =>
      'Ferme l’application Musync (comme le bouton retour système sur '
      'l’écran d’accueil). Sans argument.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Fermer l’application.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    // Comme le bouton système : l'activité se termine, le processus suit.
    SystemNavigator.pop();
    return AiToolResult.ok('Application fermée.');
  }
}

/// Bascule la bulle flottante de paroles.
///
/// Branché sur le même notifier que le bouton de « Lecture en cours »
/// (`lyricsBubbleProvider`) : un seul état, pas de doublon. Si la bulle est
/// active elle se désactive, sinon elle démarre (la permission d'affichage
/// par-dessus les autres applis peut être demandée par Android).
class ToggleBubbleTool extends AiTool {
  const ToggleBubbleTool();

  @override
  String get name => 'toggle_bubble';

  @override
  String get description =>
      'Active ou désactive la bulle flottante de paroles (bascule). Sans '
      'argument. La bulle ne s’affiche que par-dessus les autres applis, '
      'jamais dans Musync.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Basculer la bulle flottante.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    final controller = ctx.ref.read(lyricsBubbleProvider.notifier);
    if (ctx.ref.read(lyricsBubbleProvider).active) {
      await controller.stop();
      return AiToolResult.ok('Bulle flottante désactivée.');
    }
    switch (await controller.start()) {
      case BubbleStart.started:
        return AiToolResult.ok(
          'Bulle flottante activée — elle s’affiche par-dessus les autres '
          'applis.',
        );
      case BubbleStart.permissionDenied:
        return AiToolResult.fail(
          'Permission d’affichage par-dessus les autres applis refusée : '
          'accordez-la dans les réglages Android.',
        );
      case BubbleStart.failed:
        return AiToolResult.fail('La bulle n’a pas pu démarrer.');
    }
  }
}
