import 'package:flutter/material.dart';
import 'package:musync/core/utils/snackbar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/ui/embed_lyrics_action.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/sync_editor/data/timestamp_input.dart';
import 'package:musync/features/sync_editor/providers/sync_editor_provider.dart';
import 'package:musync/features/sync_editor/ui/widgets/lyric_line_tile.dart';

/// The overflow menu's entries.
///
/// One entry, and still an enum: a `PopupMenuButton` needs a non-null value per
/// item or the selection is indistinguishable from a dismissal, and the switch
/// on it means adding an entry without handling it will not compile.
enum _EditorMenuAction { resetTimings }

/// Musicolet-style timing editor.
///
/// The workflow it exists to support: play the track, and tap "Caler" once per
/// line as it is sung. Everything else — nudging, global offset, editing the
/// text — is repair work around that one gesture.
class SyncEditorScreen extends ConsumerStatefulWidget {
  final Song song;

  /// Which half to open on (T4).
  ///
  /// The two entries in the player's lyrics sheet both land here, and used to
  /// land on the same thing — the screen picked its own mode from the file.
  /// "Éditer le texte" now opens the plain editor and "Ajuster la
  /// synchronisation" the timing one, which is the distinction the menu was
  /// already promising. Null keeps the old behaviour of letting the file
  /// decide, for anything reaching this screen another way.
  final SyncMode? initialMode;

  const SyncEditorScreen({super.key, required this.song, this.initialMode});

  @override
  ConsumerState<SyncEditorScreen> createState() => _SyncEditorScreenState();
}

class _SyncEditorScreenState extends ConsumerState<SyncEditorScreen> {
  /// Fixed row height, so scrolling to a line is exact arithmetic rather than
  /// a guess at where a variable-height tile ended up.
  static const double _rowExtent = 64;

  /// Vertical inset on the line list. Named because the scroll arithmetic has
  /// to agree with it — see [_scrollToCursor].
  static const double _listPadding = 8;

  final ScrollController _scrollController = ScrollController();
  int? _lastScrolledTo;

  /// Applied once, after the file has been read.
  ///
  /// The load decides a mode of its own from what the file holds, so an
  /// override set before it lands would simply be overwritten.
  bool _modeApplied = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  SyncEditorNotifier get _editor =>
      ref.read(syncEditorProvider(widget.song).notifier);

  void _scrollToCursor(int cursor) {
    if (_lastScrolledTo == cursor || !_scrollController.hasClients) return;
    _lastScrolledTo = cursor;

    final viewport = _scrollController.position.viewportDimension;
    // `_listPadding` is the list's leading inset, so row `cursor` starts there
    // rather than at zero. Leaving it out is what put the active line half a
    // screen too low in the player — see SyncedLyricsView._centerLine. Here the
    // inset is only 8 px, so the error was invisible; the arithmetic is still
    // wrong, and the two views should not disagree about how centring works.
    final target =
        _listPadding +
        (cursor * _rowExtent) +
        (_rowExtent / 2) -
        (viewport / 2);
    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// Stamps [index] at the playhead. Reading the position from the service
  /// rather than from the position stream matters: the stream ticks a few
  /// times a second, and rounding a tap down to the last tick would bake a
  /// systematic delay into every line.
  void _stamp(int index) {
    final position = ref.read(audioPlayerServiceProvider).position;
    _editor.updateTimestamp(index, position);
    _editor.setCursor(index + 1);
  }

  /// Hears the cursor line land, and shifts the whole song by the difference.
  ///
  /// The playhead is read off the service rather than the position stream for
  /// the same reason stamping does: the stream ticks a few times a second, and
  /// rounding down to the last tick would bake a delay into the very
  /// measurement this is meant to remove.
  void _alignHere() {
    final position = ref.read(audioPlayerServiceProvider).position;
    final state = ref.read(syncEditorProvider(widget.song));
    final delta = _editor.alignAllFrom(state.cursor, position);

    final message = delta == null
        ? 'Ligne calée. Il faut une ligne déjà datée pour décaler le reste.'
        : delta == Duration.zero
        ? 'Déjà au bon endroit — rien à décaler.'
        : 'Tout décalé de ${delta.isNegative ? '−' : '+'}'
              '${delta.abs().inMilliseconds} ms.';

    ScaffoldMessenger.of(context).showOnly(SnackBar(content: Text(message)));
  }

  void _stampCursor() {
    final position = ref.read(audioPlayerServiceProvider).position;
    if (_editor.stampCursorAt(position) == null) {
      ScaffoldMessenger.of(context).showOnly(
        const SnackBar(content: Text('Toutes les lignes sont calées.')),
      );
    }
  }

  Future<void> _save(SyncEditorState state) async {
    _editor.setSaving(true);
    final outcome = await embedLyrics(
      context,
      ref,
      filePath: widget.song.filePath,
      // SYLT only carries timing; USLT keeps the lyric readable in players that
      // ignore synchronised frames, so both are written together.
      synced: state.asSyncedLyrics,
      unsynced: state.asUnsyncedLyrics,
      successMessage:
          '${state.asSyncedLyrics.length} lignes calées enregistrées.',
      // The editor owns this track's whole lyric state, clearing a
      // timing included, so it is the one caller allowed to replace.
      onPlainOverSynced: PlainOverSynced.replace,
    );

    if (!mounted) return;
    if (outcome == EmbedOutcome.written) {
      _editor.markSaved();
      // No snackbar here: embedLyrics shows one, and it carries the undo.
      Navigator.pop(context);
    } else {
      _editor.setSaving(false);
    }
  }

  /// Guards the back gesture so timing work isn't lost to a stray swipe.
  Future<bool> _confirmDiscard(SyncEditorState state) async {
    if (!state.hasChanges) return true;

    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abandonner les modifications ?'),
        content: const Text(
          'Les timestamps modifiés n\'ont pas été enregistrés dans le fichier.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Continuer l\'édition'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Abandonner'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(syncEditorProvider(widget.song));
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;

    // Highlighting follows the sorted view, since that is the order playback
    // actually visits the lines in.
    final playingLine = state.asSyncedLyrics.getLineAt(position);

    final requested = widget.initialMode;
    if (!state.isLoading && !_modeApplied && requested != null) {
      _modeApplied = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editor.setMode(requested);
      });
    }

    if (state.mode == SyncMode.synced) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToCursor(state.cursor);
      });
    }

    return PopScope(
      canPop: !state.hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmDiscard(state);
        // build()'s own context, not State.context — the dialog above awaits,
        // so it has to be re-checked rather than the State's mounted flag.
        if (!leave || !context.mounted) return;
        Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          // Says which of the two jobs this is. Both entries in the player's
          // lyrics sheet come here, and an identical header was most of what
          // made them look like the same screen.
          title: Text(
            state.mode == SyncMode.simple
                ? 'Texte des paroles'
                : 'Synchronisation',
          ),
          actions: [
            if (state.isSaving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.save_outlined),
                tooltip: 'Enregistrer dans le fichier',
                onPressed: state.isEmpty ? null : () => _save(state),
              ),
            // Typed on a real enum, not on `void`.
            //
            // As `PopupMenuButton<void>` the item carried no value, so the
            // selected value was null — and `PopupMenuButton` reads a null
            // result as "the menu was dismissed", calls `onCanceled` and never
            // `onSelected`. Tapping "Réinitialiser le calage" did precisely
            // nothing, and could not have: the callback was unreachable.
            PopupMenuButton<_EditorMenuAction>(
              tooltip: 'Autres actions',
              onSelected: (action) => switch (action) {
                _EditorMenuAction.resetTimings => _confirmResetTimings(),
              },
              itemBuilder: (context) => [
                PopupMenuItem<_EditorMenuAction>(
                  value: _EditorMenuAction.resetTimings,
                  enabled: !state.isEmpty,
                  child: const ListTile(
                    leading: Icon(Icons.restart_alt),
                    title: Text('Réinitialiser le calage'),
                    subtitle: Text('Efface tous les horodatages'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(64),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: SegmentedButton<SyncMode>(
                      segments: const [
                        ButtonSegment(
                          value: SyncMode.simple,
                          label: Text('Simple'),
                          icon: Icon(Icons.notes),
                        ),
                        ButtonSegment(
                          value: SyncMode.synced,
                          label: Text('Synchronisé'),
                          icon: Icon(Icons.schedule),
                        ),
                      ],
                      selected: {state.mode},
                      onSelectionChanged: (selection) =>
                          _editor.setMode(selection.first),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: state.isLoading
            ? const Center(child: CircularProgressIndicator())
            : state.mode == SyncMode.simple
            ? _PlainTextEditor(
                text: state.asUnsyncedLyrics.text,
                onChanged: _editor.replaceAllText,
              )
            : _buildLineList(state, playingLine, scheme),
        bottomNavigationBar: state.isLoading
            ? null
            : _TransportBar(
                song: widget.song,
                position: position,
                state: state,
                onStampCursor: _stampCursor,
                onOffset: _editor.offsetAll,
                onResetOffset: _editor.resetOffset,
                onAlignHere: _alignHere,
              ),
      ),
    );
  }

  Widget _buildLineList(
    SyncEditorState state,
    int? playingLine,
    ColorScheme scheme,
  ) {
    if (state.isEmpty) return const _NoLyrics();

    return ListView.builder(
      controller: _scrollController,
      itemCount: state.lines.length,
      itemExtent: _rowExtent,
      padding: const EdgeInsets.symmetric(vertical: _listPadding),
      itemBuilder: (context, index) {
        return LyricLineTile(
          line: state.lines[index],
          isPlaying:
              playingLine != null &&
              state.asSyncedLyrics.lines[playingLine] == state.lines[index],
          isCursor: index == state.cursor,
          showTimestamp: true,
          onStamp: () => _stamp(index),
          onSelect: () {
            _editor.setCursor(index);
            // Selecting a line seeks to it — unless it has no time to seek to,
            // either because it hasn't been stamped yet or because the user
            // stripped it on purpose.
            final timestamp = state.lines[index].timestamp;
            if (timestamp != null && timestamp > Duration.zero) {
              ref.read(audioPlayerServiceProvider).seekTo(timestamp);
            }
          },
          onAction: (action) => _handleAction(action, index, state),
        );
      },
    );
  }

  void _handleAction(LyricLineAction action, int index, SyncEditorState state) {
    switch (action) {
      case LyricLineAction.editText:
        _editLineText(index, state.lines[index].text);
      // Nudging carries everything below it along, per the spec: a nudge on the
      // first line shifts the whole song. Generalised to any line, that also
      // fixes the common case of a lyric that only starts drifting part-way
      // through, without disturbing the part already timed correctly.
      //
      // Moving a single line in isolation is still possible — that is what
      // typing the timestamp is for, and it is more precise than repeated taps.
      case LyricLineAction.nudgeBack:
        _editor.nudgeFrom(index, const Duration(milliseconds: -_offsetStepMs));
      case LyricLineAction.nudgeForward:
        _editor.nudgeFrom(index, const Duration(milliseconds: _offsetStepMs));
      case LyricLineAction.editTimestamp:
        _editTimestamp(index, state.lines[index].timestamp);
      case LyricLineAction.retime:
        _editor.resetLineTiming(index);
      case LyricLineAction.clearTimestamp:
        _editor.clearTimestamp(index);
      case LyricLineAction.insertBelow:
        _editor.insertLineAfter(index);
      case LyricLineAction.delete:
        _editor.removeLine(index);
    }
  }

  /// Opens the timestamp for direct typing.
  ///
  /// Tapping "Caler" places a line at the playhead, which is the fast path but
  /// a blunt one — it cannot express "half a second earlier than I managed to
  /// tap". Being able to type `01:23.45` is what makes the last few tenths
  /// reachable at all.
  Future<void> _editTimestamp(int index, Duration? current) async {
    final result = await showDialog<Duration>(
      context: context,
      builder: (context) => _TimestampDialog(initial: current),
    );
    if (result != null) _editor.updateTimestamp(index, result);
  }

  /// Wipes every timestamp, after asking.
  ///
  /// The one action in this editor that another tap cannot walk back: nudges,
  /// stamps and the global offset can all be re-applied, but the old timings
  /// are simply gone once this runs. Hence the confirmation, and hence saying
  /// plainly that the words survive — the button sits next to Save, and
  /// "réinitialiser" next to a lyric editor reads like it might erase the lyric.
  Future<void> _confirmResetTimings() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Réinitialiser le calage ?'),
        content: const Text(
          'Tous les horodatages seront effacés et le curseur reviendra à la '
          'première ligne. Les paroles elles-mêmes ne changent pas, et rien '
          'n\'est écrit dans le fichier tant que vous n\'enregistrez pas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Réinitialiser'),
          ),
        ],
      ),
    );
    if (confirmed == true) _editor.resetTimings();
  }

  Future<void> _editLineText(int index, String current) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => _LineTextDialog(initialText: current),
    );
    if (text != null) _editor.updateLineText(index, text);
  }
}

/// The "edit this line" dialog.
///
/// That it owns its controller is the whole point. The previous version built
/// one in the calling method and disposed it on the line after
/// `await showDialog`, which returns the moment the route is popped — while the
/// dialog's exit animation is still playing and its TextField is still mounted.
/// Pulling the controller out from under a live field is what raised
/// `'_dependents.isEmpty': is not true` and took the editor down mid-edit.
///
/// Tying the controller to the State that uses it makes the ordering
/// impossible to get wrong: Flutter disposes this widget only once the route is
/// really gone.
class _LineTextDialog extends StatefulWidget {
  final String initialText;

  const _LineTextDialog({required this.initialText});

  @override
  State<_LineTextDialog> createState() => _LineTextDialogState();
}

class _LineTextDialogState extends State<_LineTextDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Modifier la ligne'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: null,
        decoration: const InputDecoration(hintText: 'Texte de la ligne'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Valider'),
        ),
      ],
    );
  }
}

/// Plain-text mode (plan §3.3): retype or paste the whole lyric.
///
/// Kept uncontrolled — seeded once, then reporting upward — because rebuilding
/// the controller from provider state on every keystroke would fight the
/// cursor position.
class _PlainTextEditor extends StatefulWidget {
  final String text;
  final ValueChanged<String> onChanged;

  const _PlainTextEditor({required this.text, required this.onChanged});

  @override
  State<_PlainTextEditor> createState() => _PlainTextEditorState();
}

class _PlainTextEditorState extends State<_PlainTextEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.text,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Selects everything and puts it on the clipboard in one go.
  ///
  /// Selecting a whole lyric by dragging on a phone is miserable — the handles
  /// fight the scroll the moment the text is longer than the screen, which is
  /// most of the time.
  Future<void> _selectAllAndCopy() async {
    final text = _controller.text;
    final messenger = ScaffoldMessenger.of(context);

    if (text.trim().isEmpty) {
      messenger.showOnly(const SnackBar(content: Text('Rien à copier.')));
      return;
    }

    // Selected as well as copied: the selection is the visible confirmation
    // that "tout" really meant all of it.
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: text.length,
    );
    await Clipboard.setData(ClipboardData(text: text));

    final lines = text.trim().split('\n').length;
    messenger.showOnly(SnackBar(content: Text('$lines lignes copiées.')));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _selectAllAndCopy,
              icon: const Icon(Icons.select_all, size: 18),
              label: const Text('Tout sélectionner et copier'),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: widget.onChanged,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                hintText: 'Collez ou tapez les paroles, une ligne par ligne…',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoLyrics extends StatelessWidget {
  const _NoLyrics();

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
            Icon(Icons.edit_note, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'Aucune parole à synchroniser',
              style: textTheme.titleMedium?.copyWith(color: scheme.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              'Passez en mode Simple pour saisir le texte, ou cherchez les '
              'paroles en ligne depuis le lecteur.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Playback transport, the stamp button, and the global offset control.
/// Step of the global offset buttons, in milliseconds.
///
/// 10 ms, not 100. A hundred is coarse enough that the correct value often sits
/// between two presses, which turns fine alignment into a choice between too
/// early and too late.
const int _offsetStepMs = 10;

class _TransportBar extends ConsumerWidget {
  final Song song;
  final Duration position;
  final SyncEditorState state;
  final VoidCallback onStampCursor;
  final ValueChanged<Duration> onOffset;
  final VoidCallback onResetOffset;

  /// Measures the drift from the cursor line and shifts the whole song by it.
  final VoidCallback onAlignHere;

  const _TransportBar({
    required this.song,
    required this.position,
    required this.state,
    required this.onStampCursor,
    required this.onOffset,
    required this.onResetOffset,
    required this.onAlignHere,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final service = ref.watch(audioPlayerServiceProvider);
    final isPlaying =
        ref.watch(playerStateProvider).valueOrNull?.playing ?? false;

    final offset = state.globalOffset.inMilliseconds;
    final offsetLabel = offset == 0
        ? 'Décalage : 0 ms'
        : 'Décalage : ${offset > 0 ? '+' : ''}$offset ms';

    return SafeArea(
      child: Material(
        color: scheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SeekBar(song: song, position: position),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.replay_5),
                    tooltip: 'Reculer de 5 s',
                    onPressed: () =>
                        service.seekBy(const Duration(seconds: -5)),
                  ),
                  IconButton.filledTonal(
                    iconSize: 30,
                    icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                    tooltip: isPlaying ? 'Pause' : 'Lecture',
                    onPressed: service.togglePlayPause,
                  ),
                  IconButton(
                    icon: const Icon(Icons.forward_5),
                    tooltip: 'Avancer de 5 s',
                    onPressed: () => service.seekBy(const Duration(seconds: 5)),
                  ),
                  // The primary action of the screen, so it gets the only
                  // filled button in the bar.
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: FilledButton.icon(
                        onPressed:
                            state.mode == SyncMode.synced && !state.isEmpty
                            ? onStampCursor
                            : null,
                        icon: const Icon(Icons.adjust, size: 18),
                        label: const Text('Caler'),
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove),
                    tooltip: 'Décaler tout de -$_offsetStepMs ms',
                    onPressed: state.isEmpty
                        ? null
                        : () => onOffset(
                            const Duration(milliseconds: -_offsetStepMs),
                          ),
                  ),
                  SizedBox(
                    width: 132,
                    child: Text(
                      offsetLabel,
                      textAlign: TextAlign.center,
                      style: textTheme.labelLarge?.copyWith(
                        color: offset == 0
                            ? scheme.onSurfaceVariant
                            : scheme.primary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Décaler tout de +$_offsetStepMs ms',
                    onPressed: state.isEmpty
                        ? null
                        : () => onOffset(
                            const Duration(milliseconds: _offsetStepMs),
                          ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.restart_alt),
                    tooltip: 'Annuler le décalage',
                    // Nothing to undo when the running total is zero, and a
                    // live button that does nothing is worse than a dead one.
                    onPressed: offset == 0 ? null : onResetOffset,
                  ),
                ],
              ),
              // Full width and on its own line because it is a timing gesture:
              // the user taps the instant the line should land, and a cramped
              // target costs exactly the precision the button exists to give.
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: state.mode == SyncMode.synced && !state.isEmpty
                      ? onAlignHere
                      : null,
                  icon: const Icon(Icons.published_with_changes, size: 18),
                  label: const Text('Caler ici et décaler tout'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Seek bar that only seeks once, on release.
///
/// Seeking on every pixel of a drag floods the platform player with requests
/// and makes the audio stutter; the thumb follows the finger locally instead.
class _SeekBar extends ConsumerStatefulWidget {
  final Song song;
  final Duration position;

  const _SeekBar({required this.song, required this.position});

  @override
  ConsumerState<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<_SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final duration =
        ref.watch(durationProvider).valueOrNull ?? widget.song.durationValue;
    final max = duration.inMilliseconds.toDouble();
    if (max <= 0) return const SizedBox(height: 48);

    final value = (_dragValue ?? widget.position.inMilliseconds.toDouble())
        .clamp(0.0, max);

    return Column(
      children: [
        Slider(
          value: value,
          max: max,
          onChanged: (v) => setState(() => _dragValue = v),
          onChangeEnd: (v) {
            ref
                .read(audioPlayerServiceProvider)
                .seekTo(Duration(milliseconds: v.toInt()));
            setState(() => _dragValue = null);
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                LrcParser.formatTimestamp(
                  Duration(milliseconds: value.toInt()),
                ),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                LrcParser.formatTimestamp(duration),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Types a timestamp directly, in the `mm:ss.cc` form the chips show.
///
/// "Caler" places a line at the playhead, which is fast but blunt: it cannot
/// express "a quarter-second before I managed to tap". Typing the value is what
/// puts the last few hundredths within reach.
class _TimestampDialog extends StatefulWidget {
  final Duration? initial;

  const _TimestampDialog({required this.initial});

  @override
  State<_TimestampDialog> createState() => _TimestampDialogState();
}

class _TimestampDialogState extends State<_TimestampDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial == null
        ? ''
        : LrcParser.formatTimestamp(widget.initial!),
  );

  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = TimestampInput.parse(_controller.text);
    if (parsed == null) {
      setState(() => _error = 'Format attendu : mm:ss.cc');
      return;
    }
    Navigator.pop(context, parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Horodatage de la ligne'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: '01:23.45',
          errorText: _error,
          helperText: 'Minutes:secondes.centièmes',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Valider')),
      ],
    );
  }
}
