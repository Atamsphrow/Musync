/// Settings: lyrics sources (P5) and the debug log (T9).
///
/// Two tabs rather than two screens because they are both "things you go and
/// look at when something isn't working", and the report asked for the log to
/// live alongside the sources.
library;

import 'package:flutter/material.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musync/core/app_info.dart';
import 'package:musync/core/services/debug_log.dart';
import 'package:musync/core/services/permission_service.dart';
import 'package:musync/features/settings/providers/audio_diagnostic_provider.dart';
import 'package:musync/features/settings/data/hidden_photos.dart';
import 'package:musync/features/settings/data/playback_settings.dart';
import 'package:musync/features/settings/providers/playback_settings_provider.dart';
import 'package:musync/features/settings/data/lyrics_source_config.dart';
import 'package:musync/features/settings/providers/settings_provider.dart';
import 'package:musync/features/settings/ui/ai_tab.dart';
import 'package:musync/features/settings/ui/backup_tab.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Paramètres'),
          actions: [
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: 'À propos',
                onPressed: () => _showAbout(context),
              ),
            ),
          ],
          bottom: const TabBar(
            // Scrollable: four labels do not fit side by side on a phone, and
            // squeezing them in would cost the icons.
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Sources', icon: Icon(Icons.travel_explore)),
              Tab(text: 'IA', icon: Icon(Icons.auto_awesome_outlined)),
              Tab(
                text: 'Historique',
                icon: Icon(Icons.settings_backup_restore),
              ),
              Tab(text: 'Journal', icon: Icon(Icons.bug_report_outlined)),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_SourcesTab(), AiTab(), BackupTab(), _DebugTab()],
        ),
      ),
    );
  }
}

/// Who this belongs to, and which build is installed.
void _showAbout(BuildContext context) {
  final textTheme = Theme.of(context).textTheme;
  final scheme = Theme.of(context).colorScheme;

  showAboutDialog(
    context: context,
    applicationName: AppInfo.name,
    applicationVersion: 'Version ${AppInfo.version}',
    // Drawn, not loaded. The launcher icon is an Android resource, not a
    // Flutter asset, so `Image.asset` could only ever fail and fall back —
    // a failure path taken every single time is not a fallback, it is dead
    // weight.
    applicationIcon: Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Icons.lyrics_rounded,
        size: 28,
        color: scheme.onPrimaryContainer,
      ),
    ),
    children: [
      const SizedBox(height: 12),
      Text(AppInfo.tagline, style: textTheme.bodyMedium),
      const SizedBox(height: 16),
      Row(
        children: [
          Icon(Icons.person_outline, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Text('Propriétaire', style: textTheme.labelMedium),
        ],
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          Expanded(
            child: SelectableText(
              AppInfo.owner,
              style: textTheme.titleMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _OwnerAvatar(scheme: scheme),
        ],
      ),
      const SizedBox(height: 16),
      Text(
        AppInfo.packageId,
        style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    ],
  );
}

/// The owner's picture, or the silhouette when there isn't one.
///
/// The asset is declared as a directory in `pubspec.yaml` rather than a file, so
/// the app builds and runs whether or not `owner.png` has been dropped in. The
/// fallback is a real path here, not dead weight: unlike the launcher icon —
/// which is an Android resource and could never load as a Flutter asset — this
/// one genuinely may or may not be present.
class _OwnerAvatar extends StatelessWidget {
  final ColorScheme scheme;

  const _OwnerAvatar({required this.scheme});

  static const double _size = 40;

  /// The circular thumbnail: cropped square, so the head fills the circle.
  static const String thumbnail = 'assets/images/owner.png';

  /// The photograph as it was taken — whole frame, nothing cut off.
  ///
  /// Two files rather than one, and on purpose. A circle wants a square with the
  /// face centred in it, so the thumbnail is cropped; but cropping is a decision
  /// about a 40 dp circle, and it has no business being imposed on someone who
  /// tapped precisely to see the picture.
  static const String full = 'assets/images/owner_full.jpg';

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        // The barrier is what closes it, which is why the picture below does not.
        builder: (_) => const _PhotoViewer(),
      ),
      customBorder: const CircleBorder(),
      child: ClipOval(
        child: Image.asset(
          thumbnail,
          width: _size,
          height: _size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          // Silences the "unable to load asset" exception too: without a
          // builder, a missing asset paints the red error box in debug.
          errorBuilder: (context, error, stack) => Container(
            width: _size,
            height: _size,
            color: scheme.primaryContainer,
            child: Icon(
              Icons.person,
              size: 24,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

/// The enlarged photograph.
///
/// Tapping the picture does **not** close it — it counts. Twelve taps and the
/// photograph is replaced by a hidden one; a tap anywhere outside it is what
/// closes the view. That is the whole trick: the gesture that looks like "close"
/// is the gesture that counts, so someone who does not know simply taps once,
/// sees nothing happen, and taps outside to leave.
///
/// The hidden pictures form a cycle rather than a single reveal. Twelve taps
/// gives the first, closing and doing it again gives the second, and after the
/// last one it comes round to the first — see [HiddenPhotos]. The owner's own
/// photograph is never replaced by any of this: it is what the view always opens
/// on.
///
/// Silent by design. No counter, no hint, no message at any point — the eleventh
/// tap has to look exactly like the first, or anyone watching learns there is
/// something to find.
///
/// Not a [Dialog]: a Dialog fills the screen and would swallow the taps meant
/// for the barrier. This is the picture alone, centred, with everything around
/// it left to `showDialog`'s own dismissible barrier — so "outside the photo"
/// means outside the photo, exactly.
class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer();

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  static const int _tapsToReveal = 12;

  int _taps = 0;

  /// The hidden picture on show, or null while the owner's is.
  String? _revealed;

  /// No timeout on the run of taps.
  ///
  /// The view stays open and waits, so closing it *is* the reset — a clock as
  /// well would only add a way to be halfway there and not know it.
  Future<void> _tap() async {
    if (_revealed != null) return;

    _taps++;
    if (_taps < _tapsToReveal) return;

    final photo = await HiddenPhotos.next();
    if (!mounted || photo == null) return;
    setState(() => _revealed = photo);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    return Center(
      child: GestureDetector(
        onTap: _tap,
        child: ConstrainedBox(
          // Sized to the picture, not to the screen: the box has to end where
          // the photograph ends, or the empty space beside it would count as a
          // tap on it instead of falling through to the barrier.
          constraints: BoxConstraints(
            maxWidth: size.width - 32,
            maxHeight: size.height - 32,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Image.asset(
              _revealed ?? _OwnerAvatar.full,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              // Falls back to the thumbnail rather than to nothing: a cropped
              // picture is still a picture, and an empty view would read as a
              // broken button.
              errorBuilder: (context, error, stack) => Image.asset(
                _OwnerAvatar.thumbnail,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) =>
                    const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sources ──

class _SourcesTab extends ConsumerWidget {
  const _SourcesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourcesAsync = ref.watch(lyricsSourcesProvider);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: sourcesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (sources) => ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Musync interroge toutes les sources actives en parallèle et '
                'classe les résultats par pertinence. Une source ajoutée ici '
                'doit exposer l\'API de LRCLIB — c\'est le cas des instances '
                'auto-hébergées et des miroirs.',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final source in sources)
              _SourceTile(source: source, key: ValueKey(source.id)),
            const Divider(height: 32),
            const _LyricsOffsetSetting(),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
    );
  }
}

/// The residual manual compensation for T20.
///
/// Display only: it shifts when the lines light up, and never touches a tag —
/// so it cannot be confused with Décaler, which writes the timestamps of one
/// track, and it cannot corrupt a file.
///
/// It exists as a net, not as the fix. The lag that was reported against
/// Musicolet came from the line-transition interval and is corrected at the
/// source (see `lineRefreshInterval`); this is here for what the app cannot
/// measure about a given device or a badly encoded file. Zero should be right.
class _LyricsOffsetSetting extends ConsumerWidget {
  const _LyricsOffsetSetting();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final offset = ref.watch(playbackSettingsProvider).lyricsOffsetMs;
    final notifier = ref.read(playbackSettingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'Affichage des paroles',
            style: textTheme.titleSmall?.copyWith(color: scheme.primary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            "Décale le moment où chaque ligne s'allume, sans toucher aux "
            "horodatages enregistrés. À laisser à zéro : le retard constaté "
            "face à Musicolet est corrigé à la source. Négatif = les lignes "
            "s'allument plus tôt.",
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        ListTile(
          title: const Text('Décalage global'),
          subtitle: Text(
            offset == 0 ? 'Aucun' : '${offset > 0 ? '+' : ''}$offset ms',
          ),
          trailing: offset == 0
              ? null
              : IconButton(
                  tooltip: 'Remettre à zéro',
                  icon: const Icon(Icons.restart_alt),
                  onPressed: () => notifier.setLyricsOffsetMs(0),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Slider(
            value: offset.toDouble(),
            min: -PlaybackSettings.maxOffsetMs.toDouble(),
            max: PlaybackSettings.maxOffsetMs.toDouble(),
            // 50 ms steps: finer than anyone can hear the difference of, and
            // coarse enough that the slider can actually be aimed with a thumb.
            divisions: (PlaybackSettings.maxOffsetMs * 2) ~/ 50,
            label: '$offset ms',
            // Written on every change rather than on release: the lines move as
            // the slider is dragged, which is the only way to tell when it is
            // right. The notifier ignores a value equal to the current one, so
            // dragging within one step costs nothing.
            onChanged: (value) => notifier.setLyricsOffsetMs(value.round()),
          ),
        ),
        const _EncoderDelayLine(),
      ],
    );
  }
}

/// What the track playing right now declares about its encoder delay.
///
/// The measurement T20 asked for, put where the decision is made. The ticket
/// supposed the constant lag came from the silence LAME adds at the start of a
/// file; this reads that field out of the file itself, so the hypothesis can be
/// checked against the user's own library instead of argued about.
class _EncoderDelayLine extends ConsumerWidget {
  const _EncoderDelayLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final info = ref.watch(currentTrackGaplessProvider).valueOrNull;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Text(
        info == null
            ? "Lancez un morceau pour voir ce que son encodeur déclare."
            : "Morceau en cours — ${info.describe()}",
        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _SourceTile extends ConsumerWidget {
  final LyricsSourceConfig source;

  const _SourceTile({super.key, required this.source});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(lyricsSourcesProvider.notifier);

    return SwitchListTile(
      value: source.enabled,
      onChanged: (value) => notifier.setEnabled(source.id, value),
      title: Text(source.name),
      subtitle: Text(source.baseUrl, maxLines: 1, overflow: TextOverflow.fade),
      secondary: source.isBuiltIn
          // Nothing to edit or delete on the bundled entry: leaving no way back
          // to a working default would be a trap, so it can only be switched
          // off.
          ? const Tooltip(
              message: 'Source intégrée',
              child: Icon(Icons.verified_outlined),
            )
          : PopupMenuButton<_SourceAction>(
              onSelected: (action) => switch (action) {
                _SourceAction.edit => _openEditor(context, ref, source: source),
                _SourceAction.delete => _confirmDelete(context, ref, source),
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _SourceAction.edit,
                  child: ListTile(
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Modifier'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: _SourceAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('Supprimer'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
    );
  }
}

enum _SourceAction { edit, delete }

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  LyricsSourceConfig source,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Supprimer « ${source.name} » ?'),
      content: const Text(
        'La source ne sera plus interrogée. Les paroles déjà enregistrées dans '
        'vos fichiers ne changent pas.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await ref.read(lyricsSourcesProvider.notifier).remove(source.id);
  }
}

Future<void> _openEditor(
  BuildContext context,
  WidgetRef ref, {
  LyricsSourceConfig? source,
}) async {
  final result = await showDialog<({String name, String baseUrl})>(
    context: context,
    builder: (context) => _SourceDialog(existing: source),
  );
  if (result == null) return;

  final notifier = ref.read(lyricsSourcesProvider.notifier);
  if (source == null) {
    await notifier.add(name: result.name, baseUrl: result.baseUrl);
  } else {
    await notifier.edit(source.id, name: result.name, baseUrl: result.baseUrl);
  }
}

/// Add/edit form. Owns its controllers, for the reason spelled out in
/// `_LineTextDialog` — a controller disposed on the line after `await
/// showDialog` dies while its field is still on screen.
class _SourceDialog extends StatefulWidget {
  final LyricsSourceConfig? existing;

  const _SourceDialog({this.existing});

  @override
  State<_SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<_SourceDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.existing?.baseUrl ?? '',
  );

  String? _urlError;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final error = validateBaseUrl(_url.text);
    if (error != null) {
      setState(() => _urlError = error);
      return;
    }
    final name = _name.text.trim();
    Navigator.pop(context, (
      name: name.isEmpty ? Uri.parse(_url.text.trim()).host : name,
      baseUrl: _url.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Nouvelle source' : 'Modifier la source',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Nom',
              helperText: 'Affiché à côté de chaque résultat',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Adresse',
              hintText: 'https://lrclib.net',
              errorText: _urlError,
              helperText: '/api est ajouté si vous l\'omettez',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Enregistrer')),
      ],
    );
  }
}

// ── Debug log ──

class _DebugTab extends StatefulWidget {
  const _DebugTab();

  @override
  State<_DebugTab> createState() => _DebugTabState();
}

class _DebugTabState extends State<_DebugTab> {
  /// The lowest level shown. Errors by default.
  ///
  /// The log now records everything the app does wrong, including failures it
  /// recovers from on its own — a cache it could not write, a cover it could not
  /// decode. That is what makes it worth reading, and it is also what would make
  /// it unreadable if the one error that matters arrived buried under fifty
  /// notices. So the tab opens on errors, and the rest is one tap away.
  LogLevel _floor = LogLevel.error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return AnimatedBuilder(
      animation: DebugLog.instance,
      builder: (context, _) {
        final all = DebugLog.instance.entries;
        final entries = [
          for (final e in all)
            if (e.level.index >= _floor.index) e,
        ];
        final hidden = all.length - entries.length;

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      all.isEmpty
                          ? 'Rien d\'enregistré.'
                          : '${entries.length} entrée(s)'
                                '${hidden > 0 ? ', $hidden masquée(s)' : ''}'
                                ', la plus récente en haut.',
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_sweep_outlined),
                    tooltip: 'Vider',
                    onPressed: all.isEmpty ? null : DebugLog.instance.clear,
                  ),
                  FilledButton.tonalIcon(
                    // Always the whole log, never the filtered view: a report
                    // trimmed to what happened to be on screen is a report with
                    // the context removed, and the lines just before a failure
                    // are usually the ones that explain it.
                    onPressed: all.isEmpty ? null : () => _copy(context),
                    icon: const Icon(Icons.copy_all, size: 18),
                    label: const Text('Copier'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SegmentedButton<LogLevel>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: LogLevel.error, label: Text('Erreurs')),
                  ButtonSegment(
                    value: LogLevel.warning,
                    label: Text('+ alertes'),
                  ),
                  ButtonSegment(value: LogLevel.info, label: Text('Tout')),
                ],
                selected: {_floor},
                onSelectionChanged: (s) => setState(() => _floor = s.first),
              ),
            ),
            const _AudioDiagnostic(),
            const Divider(height: 1),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          all.isEmpty
                              ? 'Tout ce qui échoue dans l\'app arrive ici : '
                                    'erreurs d\'écriture des tags, plantages, '
                                    'échecs réseau, et même ceux dont l\'app se '
                                    'remet seule — invisibles autrement sur un '
                                    'téléphone.'
                              : 'Rien à ce niveau. Choisissez « Tout » pour voir '
                                    'les $hidden entrée(s) masquée(s).',
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) =>
                          _LogTile(entry: entries[index]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: DebugLog.instance.report()));
    messenger.showOnly(
      const SnackBar(content: Text('Journal copié dans le presse-papier.')),
    );
  }
}

/// The notification question, answered where someone would look for it.
///
/// Four releases of "les notifications ne s'affichent pas" with nothing to go
/// on. Everything checkable from the code has been checked; what remains are
/// runtime facts, and one of them — the notification permission — fails in
/// complete silence. Rather than ask the user to read the log again, the app
/// says what it knows.
class _AudioDiagnostic extends ConsumerWidget {
  const _AudioDiagnostic();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final checks = ref.watch(audioDiagnosticProvider).valueOrNull;
    if (checks == null) return const SizedBox.shrink();

    // Silent when everything is in order: a panel that only ever says "fine"
    // is a panel nobody reads.
    if (checks.every((c) => c.ok == true)) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notifications_off_outlined, color: scheme.tertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Notification de lecture',
                    style: textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  onPressed: () => ref.invalidate(audioDiagnosticProvider),
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Revérifier',
                ),
              ],
            ),
            for (final check in checks)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      check.ok == true
                          ? Icons.check_circle_outline
                          : check.ok == false
                          ? Icons.error_outline
                          : Icons.help_outline,
                      size: 16,
                      color: check.ok == true
                          ? scheme.primary
                          : check.ok == false
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(check.label, style: textTheme.bodyMedium),
                          if (check.advice != null)
                            Text(
                              check.advice!,
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (checks.any((c) => c.ok == false))
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: PermissionService.openSettings,
                  icon: const Icon(Icons.settings, size: 18),
                  label: const Text('Paramètres Android'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  final LogEntry entry;

  const _LogTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final (IconData icon, Color colour) = switch (entry.level) {
      LogLevel.info => (Icons.info_outline, scheme.onSurfaceVariant),
      LogLevel.warning => (Icons.warning_amber_outlined, scheme.tertiary),
      LogLevel.error => (Icons.error_outline, scheme.error),
    };

    final time = entry.time.toIso8601String().substring(11, 19);

    return ExpansionTile(
      leading: Icon(icon, color: colour),
      title: Text(
        entry.message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodyMedium,
      ),
      subtitle: Text(
        '$time · ${entry.source}',
        style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      // Nothing to expand when there is no stack trace, so the chevron would
      // just lie about there being more.
      trailing: entry.details == null ? const SizedBox.shrink() : null,
      children: entry.details == null
          ? const []
          : [
              Container(
                width: double.infinity,
                color: scheme.surfaceContainerHighest,
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  entry.details!,
                  style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ),
            ],
    );
  }
}
