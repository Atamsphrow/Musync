import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/features/library/data/models/song.dart';
import 'package:musync/features/lyrics/ui/embed_lyrics_action.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/sync_editor/providers/sync_editor_provider.dart';
import 'package:musync/features/sync_editor/ui/widgets/lyric_line_tile.dart';

/// Musicolet-style timing editor.
///
/// The workflow it exists to support: play the track, and tap "Caler" once per
/// line as it is sung. Everything else — nudging, global offset, editing the
/// text — is repair work around that one gesture.
class SyncEditorScreen extends ConsumerStatefulWidget {
  final Song song;

  const SyncEditorScreen({super.key, required this.song});

  @override
  ConsumerState<SyncEditorScreen> createState() => _SyncEditorScreenState();
}

class _SyncEditorScreenState extends ConsumerState<SyncEditorScreen> {
  /// Fixed row height, so scrolling to a line is exact arithmetic rather than
  /// a guess at where a variable-height tile ended up.
  static const double _rowExtent = 64;

  final ScrollController _scrollController = ScrollController();
  int? _lastScrolledTo;

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
    final target = (cursor * _rowExtent) - (viewport / 2) + (_rowExtent / 2);
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

  void _stampCursor() {
    final position = ref.read(audioPlayerServiceProvider).position;
    if (_editor.stampCursorAt(position) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Toutes les lignes sont calées.')),
      );
    }
  }

  Future<void> _save(SyncEditorState state) async {
    _editor.setSaving(true);
    final saved = await embedLyrics(
      context,
      ref,
      filePath: widget.song.filePath,
      // SYLT only carries timing; USLT keeps the lyric readable in players that
      // ignore synchronised frames, so both are written together.
      synced: state.asSyncedLyrics,
      unsynced: state.asUnsyncedLyrics,
    );

    if (!mounted) return;
    if (saved) {
      _editor.markSaved();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paroles enregistrées.')),
      );
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
    final position =
        ref.watch(positionProvider).valueOrNull ?? Duration.zero;

    // Highlighting follows the sorted view, since that is the order playback
    // actually visits the lines in.
    final playingLine = state.asSyncedLyrics.getLineAt(position);

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
          title: const Text('Synchronisation'),
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
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemBuilder: (context, index) {
        return LyricLineTile(
          line: state.lines[index],
          isPlaying: playingLine != null &&
              state.asSyncedLyrics.lines[playingLine] == state.lines[index],
          isCursor: index == state.cursor,
          showTimestamp: true,
          onStamp: () => _stamp(index),
          onSelect: () {
            _editor.setCursor(index);
            final timestamp = state.lines[index].timestamp;
            if (timestamp > Duration.zero) {
              ref.read(audioPlayerServiceProvider).seekTo(timestamp);
            }
          },
          onAction: (action) => _handleAction(action, index, state),
        );
      },
    );
  }

  void _handleAction(
    LyricLineAction action,
    int index,
    SyncEditorState state,
  ) {
    switch (action) {
      case LyricLineAction.editText:
        _editLineText(index, state.lines[index].text);
      case LyricLineAction.nudgeBack:
        _editor.nudgeLine(index, const Duration(milliseconds: -100));
      case LyricLineAction.nudgeForward:
        _editor.nudgeLine(index, const Duration(milliseconds: 100));
      case LyricLineAction.insertBelow:
        _editor.insertLineAfter(index);
      case LyricLineAction.delete:
        _editor.removeLine(index);
    }
  }

  Future<void> _editLineText(int index, String current) async {
    final controller = TextEditingController(text: current);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier la ligne'),
        content: TextField(
          controller: controller,
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
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text != null) _editor.updateLineText(index, text);
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
  late final TextEditingController _controller =
      TextEditingController(text: widget.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
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
              style: textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Playback transport, the stamp button, and the global offset control.
class _TransportBar extends ConsumerWidget {
  final Song song;
  final Duration position;
  final SyncEditorState state;
  final VoidCallback onStampCursor;
  final ValueChanged<Duration> onOffset;

  const _TransportBar({
    required this.song,
    required this.position,
    required this.state,
    required this.onStampCursor,
    required this.onOffset,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final service = ref.watch(audioPlayerServiceProvider);
    final isPlaying = ref.watch(playerStateProvider).valueOrNull?.playing ?? false;

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
                        onPressed: state.mode == SyncMode.synced && !state.isEmpty
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
                    tooltip: 'Décaler toutes les lignes de -100 ms',
                    onPressed: state.isEmpty
                        ? null
                        : () => onOffset(const Duration(milliseconds: -100)),
                  ),
                  SizedBox(
                    width: 150,
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
                    tooltip: 'Décaler toutes les lignes de +100 ms',
                    onPressed: state.isEmpty
                        ? null
                        : () => onOffset(const Duration(milliseconds: 100)),
                  ),
                ],
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

    final duration = ref.watch(durationProvider).valueOrNull ??
        widget.song.durationValue;
    final max = duration.inMilliseconds.toDouble();
    if (max <= 0) return const SizedBox(height: 48);

    final value =
        (_dragValue ?? widget.position.inMilliseconds.toDouble()).clamp(0.0, max);

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
