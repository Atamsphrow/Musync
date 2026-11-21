import 'package:flutter/material.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/data/providers/lyrics_provider_interface.dart';
import 'package:musync/features/settings/providers/ai_settings_provider.dart';
import 'package:musync/features/lyrics/data/filename_guess.dart';
import 'package:musync/features/lyrics/data/search_prefill.dart';
import 'package:musync/features/lyrics/data/search_variants.dart';
import 'package:musync/features/lyrics/providers/search_provider.dart';
import 'package:musync/features/lyrics/data/lyrics_align.dart';
import 'package:musync/features/lyrics/ui/embed_lyrics_action.dart';
import 'package:musync/features/lyrics/ui/source_picker_sheet.dart';

/// Le 2e essai automatique (Deviner Artiste/Titre appliqué tout seul)
/// doit-il se déclencher après la 1re recherche ?
///
/// Fonction pure, pour être testée sans écran. Il se déclenche quand la
/// recherche n'a rien donné, OU quand elle a donné des résultats mais
/// aucune parole synchronisée : un fournisseur flou qui trouve du texte
/// brut ne doit pas empêcher les fournisseurs exacts d'être interrogés
/// avec la requête devinée.
///
/// Jamais quand : la recherche a été annulée par le ×, une recherche est
/// en cours, la recherche a échoué, ou les champs ont été modifiés depuis
/// (correction manuelle).
bool shouldAutoRetryWithGuess({
  required bool cancelled,
  required bool loading,
  required bool hasError,
  required bool hasResults,
  required bool hasSyncedResult,
  required bool fieldsChanged,
}) {
  if (cancelled || loading || hasError || fieldsChanged) return false;
  return !hasResults || !hasSyncedResult;
}

/// Online lyrics lookup (plan §3.4).
///
/// Seeded from the file's own tags and searched immediately, since that is
/// right most of the time; the fields stay editable for the files whose tags
/// are wrong, which is the case the plan calls out.
class LyricsSearchScreen extends ConsumerStatefulWidget {
  final Song song;

  /// Requête pré-remplie (venue du vérificateur ou de l'assistant IA) :
  /// elle prime sur les tags du morceau.
  final String? initialTitle;

  /// Voir [initialTitle].
  final String? initialArtist;

  const LyricsSearchScreen({
    super.key,
    required this.song,
    this.initialTitle,
    this.initialArtist,
  });

  @override
  ConsumerState<LyricsSearchScreen> createState() => _LyricsSearchScreenState();
}

class _LyricsSearchScreenState extends ConsumerState<LyricsSearchScreen> {
  late final TextEditingController _titleController = TextEditingController(
    text: widget.initialTitle ?? widget.song.title,
  );
  late final TextEditingController _artistController = TextEditingController(
    text: widget.initialArtist ?? widget.song.artist,
  );

  /// Valeurs de départ des champs (tags du fichier) : la vérification
  /// avant recherche ne remplace un champ que s'il n'a pas été retouché
  /// à la main — une correction tapée par l'utilisateur prime sur le deviné.
  late final String _initialTitle =
      widget.initialTitle ?? widget.song.title;
  late final String _initialArtist =
      widget.initialArtist ?? widget.song.artist;

  /// True while a model is being asked. It can take a few seconds, and a
  /// button that looks idle invites a second press.
  bool _guessing = false;

  /// The last full guess (heuristic, completed by the model when one
  /// answered), and which model gave it. The file does not change while the
  /// screen is open: the automatic second attempt after « Deviner » reuses
  /// it instead of asking the model the same question a second time.
  FilenameGuess? _guessed;
  String? _guessedBy;

  /// Whether [_guessed] is final: a model answered, or none is configured.
  /// A guess made while every model failed is the heuristic's alone, and a
  /// later press asks the models again.
  bool _guessSettled = false;

  /// What the file name says, for the ranking (a candidate agreeing with it
  /// on title and artist ranks higher): the full guess once made, the
  /// heuristic until then. Null when the name says nothing.
  FilenameGuess? get _rankingGuess {
    final guess = _guessed ?? FilenameParser.parse(widget.song.filePath);
    return guess.title.trim().isEmpty && guess.artist.trim().isEmpty
        ? null
        : guess;
  }

  /// Incrémenté à chaque recherche lancée « pour de vrai » (écran ouvert,
  /// Rechercher, Entrée, Réessayer). La cascade du 2e essai se souvient de
  /// la valeur de départ et s'arrête dès qu'elle change : une recherche
  /// relancée par l'utilisateur ne doit jamais être suivie d'une variante
  /// de l'ancienne cascade. Les variantes elles-mêmes ne l'incrémentent pas.
  int _cascadeEpoch = 0;

  /// Attente maximale d'une variante de la cascade, toutes sources
  /// confondues. Les fournisseurs retentent en interne (12 s + 1 s + 12 s) :
  /// sans plafond, une variante qui échoue coûte 25 s. Les sources courant
  /// en parallèle, le pire cas mural d'une variante est ce plafond.
  static const Duration _variantMaxWait = Duration(seconds: 12);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  /// Devine l'artiste et le titre depuis le nom du fichier.
  ///
  /// L'heuristique locale d'abord, toujours (gratuite, sans réseau), puis
  /// l'IA si au moins un fournisseur est configuré et joignable. Retourne
  /// null quand le nom du fichier ne dit rien d'exploitable.
  ///
  /// [silent] coupe les snackbars : utilisé par le 2e essai automatique,
  /// qui ne doit pas bruiter l'écran quand il devine dans le vide.
  ///
  /// Le modèle reçoit aussi le dossier et les tags actuels comme indices
  /// (voir [aiFilenameHints]), et un champ qu'il laisse vide est repris de
  /// l'heuristique (voir [completeGuess]).
  Future<FilenameGuess?> _guessFromFilename({bool silent = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    final cached = _guessed;
    if (cached != null && _guessSettled) return _usable(cached, silent);

    // The heuristic first, always. It costs nothing, needs no network, and is
    // right on the regular shapes — so it is both the answer and the fallback.
    final heuristic = FilenameParser.parse(widget.song.filePath);
    var guess = heuristic;
    var settled = true;
    // Which model answered, or null when the heuristic's answer is the one being
    // shown. Named rather than a bare flag because with a fallback chain the
    // provider that answered is not necessarily the first one configured.
    String? answeredBy;

    final settings = ref.read(aiSettingsProvider).valueOrNull;
    final resolver = ref.read(aiFilenameResolverProvider);
    final statuses = ref.read(aiProviderStatusProvider.notifier);

    if (settings != null && settings.usable.isNotEmpty) {
      setState(() => _guessing = true);
      // Every configured model in turn, stopping at the first that answers.
      // One broken provider no longer takes the feature down with it, and no
      // longer produces a snackbar on every press — the intermediate failures
      // go to the log, and the user hears about it only if none of them work.
      final resolution = await resolver.resolve(
        settings: settings,
        fileName: widget.song.filePath.split(RegExp(r'[/\\]')).last,
        hints: aiFilenameHints(
          filePath: widget.song.filePath,
          title: widget.song.title,
          artist: widget.song.artist,
          album: widget.song.album,
        ),
      );
      if (!mounted) return null;
      // Feeds the per-provider indicators in Paramètres › IA, so the answer to
      // "which of my keys works" lives next to the keys.
      statuses.recordAttempts(resolution.attempts);

      if (resolution.answered) {
        guess = completeGuess(resolution.guess!, heuristic);
        answeredBy = resolution.providerName;
      } else if (resolution.allFailed) {
        settled = false;
      }
      if (resolution.allFailed && !silent) {
        // The heuristic's answer still goes into the fields below; this only
        // says why the model did not get a say.
        messenger.showOnly(
          SnackBar(
            content: Text(
              'Aucun modèle n\'a répondu. Analyse locale utilisée. '
              '${resolution.failureSummary}',
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }

      if (mounted) setState(() => _guessing = false);
    }

    if (!mounted) return null;

    _guessed = guess;
    _guessedBy = answeredBy;
    _guessSettled = settled;
    return _usable(guess, silent);
  }

  /// [guess], or null — with the message, unless [silent] — when it is
  /// empty.
  FilenameGuess? _usable(FilenameGuess guess, bool silent) {
    if (guess.title.isNotEmpty || guess.artist.isNotEmpty) return guess;
    if (!silent) {
      ScaffoldMessenger.of(context).showOnly(
        const SnackBar(
          content: Text('Le nom du fichier ne dit rien d’exploitable.'),
        ),
      );
    }
    return null;
  }

  /// Rewrites the two fields from what the file is called.
  ///
  /// For the common case where the tags are wrong — a library built from
  /// downloads is full of tracks whose artist is "Unknown" and whose title is
  /// the whole file name, decoration and all — while the name itself says
  /// perfectly clearly who and what.
  ///
  /// Only the fields are touched. Nothing reaches the file until the user picks
  /// a result, so a wrong guess costs one correction, not a bad tag.
  ///
  /// When the guess changes a field, the search runs again at once with it:
  /// pressing Deviner then Rechercher was always the next step. A guess the
  /// fields already hold says so instead of searching the same thing again.
  Future<void> _fillFromFilename() async {
    final guess = await _guessFromFilename();
    if (guess == null || !mounted) return;
    final title = guess.title.isNotEmpty ? guess.title : _titleController.text;
    final artist =
        guess.artist.isNotEmpty ? guess.artist : _artistController.text;
    final changed =
        title != _titleController.text || artist != _artistController.text;
    // Said out loud, because the fields may have been right already and the
    // user needs to see that something happened — and where it came from.
    final source = _guessedBy == null ? '' : '$_guessedBy : ';
    ScaffoldMessenger.of(context).showOnly(
      SnackBar(
        content: Text(
          !changed
              ? '${source}les champs disent déjà ce que dit le nom du fichier.'
              : guess.artist.isEmpty
              ? '${source}titre deviné, pas d’artiste dans le nom.'
              : '$source${guess.artist} — ${guess.title}',
        ),
      ),
    );
    if (!changed) return;
    setState(() {
      _titleController.text = title;
      _artistController.text = artist;
    });
    await _search(explicit: true, prefill: false);
  }

  /// Interrompt la recherche en cours (le × dans le cercle de chargement).
  /// Les résultats déjà arrivés restent affichés : ils sont valides.
  void _cancelSearch() {
    cancelLyricsSearch(ref);
  }

  /// Lance la recherche des champs courants. Le Future rendu se termine
  /// quand la recherche — et son éventuel 2e essai automatique — est finie.
  ///
  /// [prefill] : remplace un champ encore à sa valeur d'origine quand ce
  /// n'est pas vraiment un nom — inconnu, nom de fichier brut, décoration
  /// de téléchargement — par ce que dit le nom du fichier, ou par le tag
  /// nettoyé (voir [prefillTitle]). Coupé pour les variantes de la cascade,
  /// dont les champs sont déjà ce qu'on veut chercher.
  ///
  /// [maxWait] : plafond d'attente de cette recherche (voir
  /// [performLyricsSearch]). Null pour la 1re recherche.
  Future<void> _search({
    bool autoRetry = true,
    bool explicit = false,
    bool prefill = true,
    Duration? maxWait,
  }) {
    if (autoRetry) _cascadeEpoch++;
    final epoch = _cascadeEpoch;
    // Assurer l'artiste et le titre AVANT de chercher, sans gâcher de bons
    // tags : un champ n'est remplacé que s'il n'est pas vraiment un nom
    // (artiste « Unknown », titre = nom du fichier entier, « (Lyrics) »…).
    // Remplacer systématiquement par le nom du fichier transformait un
    // « Bohemian Rhapsody » propre en « Bohemian Rhapsody (Remastered
    // 2011) », que les sources exactes ne trouvent pas. L'heuristique locale
    // suffit ici — instantanée, sans réseau — et le deviné complet
    // (heuristique puis IA) reste sur le bouton Deviner et sur le 2e essai
    // automatique. Seuls les champs encore à leur valeur d'origine sont
    // concernés : une correction tapée à la main n'est jamais écrasée.
    if (prefill) {
      final filenameGuess = FilenameParser.parse(widget.song.filePath);
      var changed = false;
      if (_titleController.text == _initialTitle) {
        final next = prefillTitle(
          _titleController.text,
          filePath: widget.song.filePath,
          guess: filenameGuess,
        );
        if (next != _titleController.text) {
          _titleController.text = next;
          changed = true;
        }
      }
      if (_artistController.text == _initialArtist) {
        final next = prefillArtist(
          _artistController.text,
          guess: filenameGuess,
        );
        if (next != _artistController.text) {
          _artistController.text = next;
          changed = true;
        }
      }
      if (changed) setState(() {});
    }
    final title = _titleController.text;
    final artist = _artistController.text;
    return performLyricsSearch(
      ref,
      title: title,
      artist: artist,
      album: widget.song.album,
      durationMs: widget.song.duration,
      explicit: explicit,
      maxWait: maxWait,
      filenameGuess: _rankingGuess,
    ).then((_) async {
      if (mounted && autoRetry) await _autoRetryWithGuess(title, artist, epoch);
    });
  }

  /// Opens the "try another source" sheet for the current query.
  void _openSourcePicker() {
    showSourcePickerSheet(
      context: context,
      title: _titleController.text,
      artist: _artistController.text,
      album: widget.song.album,
      durationMs: widget.song.duration,
      filenameGuess: _rankingGuess,
    );
  }

  /// 2e essai automatique : quand la recherche ne donne rien — ou ne donne
  /// aucune parole synchronisée, typiquement un fournisseur flou qui trouve
  /// du texte brut pendant que les fournisseurs exacts restent vides —,
  /// Deviner Artiste/Titre (heuristique puis IA) est appliqué tout seul,
  /// puis une cascade de variantes est essayée (voir [buildSearchVariants]) :
  /// complet, nettoyé, titre seul. Elle s'arrête dès qu'une variante donne
  /// des paroles synchronisées. Jamais deux fois la même requête.
  ///
  /// Chaque variante est plafonnée à [_variantMaxWait]. Les résultats
  /// partiels de la 1re recherche ne sont pas perdus : si aucune variante
  /// ne trouve rien, ils reviennent à l'écran (à défaut, ceux de la
  /// première variante qui en a donné).
  ///
  /// [epoch] : valeur de [_cascadeEpoch] au départ ; la cascade s'arrête
  /// si une autre recherche a été lancée depuis.
  Future<void> _autoRetryWithGuess(
    String usedTitle,
    String usedArtist,
    int epoch,
  ) async {
    // Ce que les champs doivent contenir si personne n'y a touché : la
    // requête de la 1re recherche, puis celle de chaque variante lancée.
    var expectedTitle = usedTitle;
    var expectedArtist = usedArtist;

    // Les gardes, réévaluées telles quelles après chaque attente :
    // annulée par le × (il ne doit pas relancer une recherche derrière),
    // recherche relancée entre-temps, erreur, champs corrigés à la main.
    bool allowed() {
      if (!mounted || epoch != _cascadeEpoch) return false;
      final results = ref.read(lyricsSearchResultsProvider);
      return shouldAutoRetryWithGuess(
        cancelled: ref.read(lyricsSearchCancelledProvider),
        loading: ref.read(lyricsSearchLoadingProvider),
        hasError: ref.read(lyricsSearchErrorProvider) != null,
        hasResults: results.isNotEmpty,
        hasSyncedResult: results.any((r) => r.hasSyncedLyrics),
        fieldsChanged:
            _titleController.text != expectedTitle ||
            _artistController.text != expectedArtist,
      );
    }

    if (!allowed()) return;
    var partial = ref.read(lyricsSearchResultsProvider);
    // A name that says nothing still leaves the query itself to clean and
    // to try without its artist: an empty guess falls back to it.
    final guess =
        await _guessFromFilename(silent: true) ?? (artist: '', title: '');
    if (!mounted) return;
    if (!allowed()) return;

    final variants = buildSearchVariants(
      usedTitle: usedTitle,
      usedArtist: usedArtist,
      guessTitle: guess.title,
      guessArtist: guess.artist,
    );
    if (variants.isEmpty) return;

    for (final variant in variants) {
      if (!allowed()) return;
      setState(() {
        _titleController.text = variant.title;
        _artistController.text = variant.artist;
      });
      expectedTitle = variant.title;
      expectedArtist = variant.artist;
      await _search(
        autoRetry: false,
        prefill: false,
        maxWait: _variantMaxWait,
      );
      if (!mounted) return;
      // Chaque variante remet la liste à zéro en démarrant : on garde en
      // réserve les premiers résultats partiels rencontrés.
      final found = ref.read(lyricsSearchResultsProvider);
      if (partial.isEmpty && found.isNotEmpty) partial = found;
    }

    // Toutes les variantes ont été essayées sans paroles synchronisées
    // (sinon la garde du tour suivant aurait arrêté la boucle, et on est
    // sorti plus haut). Restauration seulement si personne n'a rien relancé
    // ni retouché entre-temps.
    if (!mounted || epoch != _cascadeEpoch) return;
    if (_titleController.text != expectedTitle ||
        _artistController.text != expectedArtist) {
      return;
    }
    if (ref.read(lyricsSearchLoadingProvider) ||
        ref.read(lyricsSearchErrorProvider) != null ||
        ref.read(lyricsSearchResultsProvider).isNotEmpty ||
        ref.read(lyricsSearchCancelledProvider)) {
      return;
    }
    ref.read(lyricsSearchResultsProvider.notifier).state = partial;
    // Les champs reviennent au meilleur deviné (le complet), pas à la
    // dernière variante — « titre seul, sans artiste » n'est pas ce que
    // l'utilisateur doit retrouver à l'écran.
    setState(() {
      _titleController.text = variants.first.title;
      _artistController.text = variants.first.artist;
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(lyricsSearchResultsProvider);
    final isLoading = ref.watch(lyricsSearchLoadingProvider);
    final error = ref.watch(lyricsSearchErrorProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Rechercher des paroles')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                _ClearableField(
                  controller: _titleController,
                  label: 'Titre',
                  icon: Icons.music_note,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                _ClearableField(
                  controller: _artistController,
                  label: 'Artiste',
                  icon: Icons.person_outline,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(explicit: true),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _guessing ? null : _fillFromFilename,
                    icon: _guessing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high, size: 18),
                    label: Text(
                      _guessing
                          ? 'Le modèle réfléchit…'
                          : 'Deviner Artiste/Titre',
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: isLoading
                        ? null
                        : () => _search(explicit: true),
                    icon: const Icon(Icons.search, size: 18),
                    label: Text(isLoading ? 'Recherche…' : 'Rechercher'),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: isLoading ? null : _openSourcePicker,
                    icon: const Icon(Icons.swap_horiz, size: 18),
                    label: const Text('Essayer une autre source'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(child: _buildResults(isLoading, error, results)),
        ],
      ),
    );
  }

  Widget _buildResults(
    bool isLoading,
    String? error,
    List<LyricsSearchResult> results,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (isLoading) {
      return Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            const CircularProgressIndicator(),
            IconButton(
              onPressed: _cancelSearch,
              tooltip: 'Annuler la recherche',
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      );
    }

    if (error != null) {
      return _Message(
        icon: Icons.cloud_off,
        title: 'Recherche impossible',
        message: error,
        action: FilledButton.icon(
          onPressed: _search,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Réessayer'),
        ),
      );
    }

    if (results.isEmpty) {
      return const _Message(
        icon: Icons.search_off,
        title: 'Aucun résultat',
        message:
            'Vérifiez le titre et l\'artiste, puis relancez la recherche. '
            'Les tags du fichier sont parfois incomplets.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final result = results[index];
        return Card(
          child: ListTile(
            title: Text(
              result.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${result.artist} • ${result.source} • '
              'confiance ${(result.confidence * 100).round()} %',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (result.hasWordTimings) ...[
                  Chip(
                    label: const Text('Mot à mot'),
                    backgroundColor: scheme.tertiaryContainer,
                    labelStyle: textTheme.labelSmall?.copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
                    side: BorderSide.none,
                  ),
                  const SizedBox(width: 6),
                ],
                Chip(
                  label: Text(result.hasSyncedLyrics ? 'Synchro' : 'Texte'),
                  // Synced results are what the app is for, so they are the ones
                  // that get the accent.
                  backgroundColor: result.hasSyncedLyrics
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  labelStyle: textTheme.labelSmall?.copyWith(
                    color: result.hasSyncedLyrics
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  side: BorderSide.none,
                ),
              ],
            ),
            onTap: () => _preview(result),
          ),
        );
      },
    );
  }

  void _preview(LyricsSearchResult result) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _PreviewSheet(
        result: result,
        onEmbed: () => _embed(sheetContext, result),
      ),
    );
  }

  Future<void> _embed(
    BuildContext sheetContext,
    LyricsSearchResult result,
  ) async {
    // One message, not two.
    //
    // This screen used to show its own confirmation on top of the one
    // `embedLyrics` shows, so picking a result produced two stacked banners
    // saying much the same thing — and the second hid the first's action.
    // The wording is handed over instead; the undo comes with it.
    //
    // The "Ajuster" shortcut that used to live here is the casualty: a snackbar
    // carries one action, and between adjusting timings and undoing a write to
    // the user's own file, the way back matters more. The sync editor is still
    // one tap away from the player.
    final outcome = await embedLyrics(
      context,
      ref,
      filePath: widget.song.filePath,
      synced: result.syncedLyrics,
      unsynced: result.unsyncedLyrics,
      // LyricsPlus and lrc.red time another recording: re-time them to
      // the file's own timings before writing.
      alignToExisting: isOtherRecordingSource(result.source),
      successMessage: result.hasSyncedLyrics
          ? '${result.syncedLyrics!.length} lignes calées enregistrées.'
          : 'Paroles enregistrées dans le fichier.',
    );
    if (outcome != EmbedOutcome.written || !mounted) return;

    if (sheetContext.mounted) Navigator.pop(sheetContext);
    if (!mounted) return;

    Navigator.pop(context);
  }
}

class _PreviewSheet extends StatelessWidget {
  final LyricsSearchResult result;
  final VoidCallback onEmbed;

  const _PreviewSheet({required this.result, required this.onEmbed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final body = result.hasSyncedLyrics
        ? result.syncedLyrics!.toLrc()
        : (result.unsyncedLyrics?.text ?? '');

    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.title, style: textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(
                  '${result.artist}${result.album != null ? ' • ${result.album}' : ''}',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                // Les mêmes pastilles que dans la liste : la feuille
                // n'affichait que le texte LRC (lignes seules), donc un
                // résultat mot à mot y ressemblait trait pour trait à un
                // résultat calé ligne à ligne — alors que les mots sont
                // bien là, et bien enregistrés par le bouton ci-dessous.
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    if (result.hasWordTimings)
                      Chip(
                        label: const Text('Mot à mot'),
                        backgroundColor: scheme.tertiaryContainer,
                        labelStyle: textTheme.labelSmall?.copyWith(
                          color: scheme.onTertiaryContainer,
                        ),
                        side: BorderSide.none,
                      ),
                    Chip(
                      label:
                          Text(result.hasSyncedLyrics ? 'Synchro' : 'Texte'),
                      backgroundColor: result.hasSyncedLyrics
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      labelStyle: textTheme.labelSmall?.copyWith(
                        color: result.hasSyncedLyrics
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                      side: BorderSide.none,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SelectableText(
                body,
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onEmbed,
                icon: const Icon(Icons.download_done, size: 18),
                label: const Text('Enregistrer dans le fichier'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const _Message({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}

/// A text field with a clear button (plan P6).
///
/// The button appears only once there is something to clear, so an empty form
/// isn't cluttered with two dead crosses. It watches the controller rather than
/// keeping its own copy of the text: one source of truth, and no listener to
/// register and tear down by hand.
class _ClearableField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  const _ClearableField({
    required this.controller,
    required this.label,
    required this.icon,
    required this.textInputAction,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Effacer',
                  onPressed: controller.clear,
                ),
        ),
      ),
    );
  }
}
