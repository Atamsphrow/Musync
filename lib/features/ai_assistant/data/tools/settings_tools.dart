/// Outils de réglages et d'aide : apparence des paroles, questions sur l'app.
library;

import 'package:musync/features/ai_assistant/data/ai_tool.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';
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
class AppHelpTool extends AiTool {
  const AppHelpTool();

  @override
  String get name => 'app_help';

  @override
  String get description =>
      'Aide sur Musync : comment caler des paroles, la bulle, les sources, '
      'les files… À appeler quand l’utilisateur pose une question sur '
      'l’app plutôt qu’une commande.';

  @override
  Map<String, Object?> get parametersSchema => {
        'type': 'object',
        'properties': {
          'question': 'string, optionnel — la question posée',
        },
      };

  @override
  Future<String> describeAction(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async =>
      'Expliquer le fonctionnement de l’app.';

  @override
  Future<AiToolResult> execute(
    AiToolContext ctx,
    Map<String, Object?> args,
  ) async {
    return AiToolResult.ok(
      'Musync est un lecteur local avec paroles synchronisées. '
      'Pour caler des paroles : ouvrir le morceau, appui long sur une ligne, '
      '« Caler », puis taper chaque ligne au rythme de la musique. '
      'La bulle flottante s’active depuis l’écran « Lecture en cours » '
      'et ne s’affiche que par-dessus les autres applis, jamais dans Musync. '
      'Tirer la liste vers le bas relance l’analyse (tags et paroles). '
      'Les paroles viennent des sources de l’onglet Sources (LRCLIB par '
      'défaut) ; le collage direct garde le texte exactement tel quel. '
      'Les files nommées se créent depuis une recherche (« Créer une file »). '
      'Le minuteur est dans « Lecture en cours ». '
      'L’appui long sur le titre « Paramètres » affiche le Journal.',
    );
  }
}
