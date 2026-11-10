import 'package:flutter/material.dart';
import 'package:musync/core/id3/lrc_parser.dart';
import 'package:musync/core/id3/models/lyrics.dart';

/// Step of a line's own nudge buttons, in milliseconds.
///
/// One constant for both the label and the action, so the menu can never say
/// one figure while the button does another. Independent of the global offset
/// (*Décaler tout*), which has its own step and its own readout.
const int kLineNudgeMs = 100;
const String _nudgeBackLabel = 'Reculer de $kLineNudgeMs ms';
const String _nudgeForwardLabel = 'Avancer de $kLineNudgeMs ms';
const String _nudgeFromBackLabel =
    'Reculer cette ligne et les suivantes de $kLineNudgeMs ms';
const String _nudgeFromForwardLabel =
    'Avancer cette ligne et les suivantes de $kLineNudgeMs ms';

/// Action chosen from a line's overflow menu.
enum LyricLineAction {
  editText,
  nudgeBack,
  nudgeForward,

  /// Shift this line and every line after it, leaving earlier lines alone.
  /// The line's own nudge moves one line only; the global offset moves them
  /// all. This is the middle case — a track that drifts from a point, where
  /// the part already timed correctly must not move.
  nudgeFromBack,
  nudgeFromForward,

  /// Put the line back to un-timed and move the cursor onto it, ready for the
  /// next tap of *Caler*.
  retime,

  /// Strip the time for good — for a structural marker that should stay in the
  /// words without ever being sung.
  clearTimestamp,

  insertBelow,
  delete,
}

/// One row of the sync editor.
///
/// Two different "current" lines can be on screen at once and they mean
/// different things: [isPlaying] is the line the song is at, [isCursor] is the
/// line the stamp button will time next. They coincide while replaying a timed
/// section and diverge while timing a new one, so each gets its own treatment —
/// a filled background for the cursor, an accent for playback.
class LyricLineTile extends StatelessWidget {
  final LyricLine line;
  final bool isPlaying;
  final bool isCursor;
  final bool showTimestamp;

  /// Tapping the timestamp stamps this line at the playhead — the gesture the
  /// whole editor is built around.
  final VoidCallback onStamp;

  /// Tapping the row moves the cursor here and seeks playback to match.
  final VoidCallback onSelect;

  final ValueChanged<LyricLineAction> onAction;

  /// Opens the timestamp dialog for direct typing. The timestamp chip
  /// calls this; the overflow menu no longer carries a redundant entry.
  final VoidCallback onEditTimestamp;

  const LyricLineTile({
    super.key,
    required this.line,
    required this.isPlaying,
    required this.isCursor,
    required this.showTimestamp,
    required this.onStamp,
    required this.onSelect,
    required this.onAction,
    required this.onEditTimestamp,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: isCursor ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              if (showTimestamp) ...[
                _TimestampChip(
                  timestamp: line.timestamp,
                  // Tap types the value, long-press grabs the playhead. The
                  // spec asks for the exact time to be reachable by hand, and a
                  // chip showing a number is where a hand goes looking for it —
                  // stamping keeps the big "Caler" button and the long-press.
                  onTap: onEditTimestamp,
                  onLongPress: onStamp,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  line.text.isEmpty ? '(ligne vide)' : line.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(
                    color: line.text.isEmpty
                        ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                        : isCursor
                        ? scheme.onSecondaryContainer
                        : isPlaying
                        ? scheme.primary
                        : scheme.onSurface,
                    fontWeight: isCursor || isPlaying
                        ? FontWeight.w600
                        : FontWeight.w400,
                    fontStyle: line.text.isEmpty
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
              ),
              PopupMenuButton<LyricLineAction>(
                onSelected: onAction,
                tooltip: 'Options de la ligne',
                icon: Icon(Icons.more_vert, color: scheme.onSurfaceVariant),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: LyricLineAction.editText,
                    child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Modifier le texte'),
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  PopupMenuDivider(),
                  _NudgeMenuEntry(onNudge: onAction),
                  _NudgeMenuEntry(
                    onNudge: onAction,
                    title: "Décaler à partir d'ici",
                    backAction: LyricLineAction.nudgeFromBack,
                    forwardAction: LyricLineAction.nudgeFromForward,
                    backTooltip: _nudgeFromBackLabel,
                    forwardTooltip: _nudgeFromForwardLabel,
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: LyricLineAction.retime,
                    child: ListTile(
                      leading: Icon(Icons.restart_alt),
                      title: Text('Réinitialiser le calage'),
                      subtitle: Text('Efface le calage, curseur ici'),
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  PopupMenuItem(
                    value: LyricLineAction.clearTimestamp,
                    child: ListTile(
                      leading: Icon(Icons.timer_off_outlined),
                      title: Text('Ligne sans horodatage'),
                      subtitle: Text('Pour un marqueur : [Refrain], [Pont]'),
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: LyricLineAction.insertBelow,
                    child: ListTile(
                      leading: Icon(Icons.playlist_add),
                      title: Text('Insérer une ligne en dessous'),
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  PopupMenuItem(
                    value: LyricLineAction.delete,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Supprimer la ligne'),
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
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

class _TimestampChip extends StatelessWidget {
  /// Two states, and they must not be confused with each other:
  ///
  ///  * a real time — the line is placed, including `Duration.zero`: a line
  ///    stamped at the very first instant is placed, not pending. Zero used
  ///    to stand in for "not stamped yet", so a `[00:00.00]` line showed
  ///    `--:--.--` and counted as unplaced (while still exporting to SYLT).
  ///  * `null` — no time. That covers both a line not stamped yet and a
  ///    structural marker (`[Refrain]`) the user stripped on purpose: the
  ///    model carries no third value to tell them apart, so the chip shows
  ///    the same "no time" face for both and the marker's own text is what
  ///    identifies it.
  final Duration? timestamp;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _TimestampChip({
    required this.timestamp,
    required this.onTap,
    required this.onLongPress,
  });

  bool get _isCleared => timestamp == null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPlaced = !_isCleared;

    return Tooltip(
      message: 'Toucher pour saisir l\'heure, appui long pour caler',
      child: Material(
        color: isPlaced
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text(
              switch (timestamp) {
                null => '—  —',
                final t => LrcParser.formatTimestamp(t),
              },
              style: TextStyle(
                // Tabular digits keep the column from jittering as the numbers
                // change under the user's finger.
                fontFeatures: const [FontFeature.tabularFigures()],
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isPlaced
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The line's own +/-100 ms step, as a menu entry that does not dismiss the
/// menu.
///
/// A plain PopupMenuItem always pops the menu route on tap — the SDK does it
/// unconditionally — which turned repeated nudging into a reopen-the-menu
/// loop. These two buttons call straight through to [onNudge] without
/// popping, so the menu stays open for the five or six taps a real
/// adjustment takes. Tapping out, or picking any other entry, still closes
/// it as usual.
class _NudgeMenuEntry extends PopupMenuEntry<LyricLineAction> {
  const _NudgeMenuEntry({
    required this.onNudge,
    this.title,
    this.backAction = LyricLineAction.nudgeBack,
    this.forwardAction = LyricLineAction.nudgeForward,
    this.backTooltip = _nudgeBackLabel,
    this.forwardTooltip = _nudgeForwardLabel,
  });

  final ValueChanged<LyricLineAction> onNudge;

  /// Title above the buttons, or null for the bare two-button row. The
  /// from-here row needs one: two identical ±100 ms rows would be
  /// indistinguishable.
  final String? title;
  final LyricLineAction backAction;
  final LyricLineAction forwardAction;
  final String backTooltip;
  final String forwardTooltip;

  @override
  double get height =>
      title == null ? kMinInteractiveDimension : kMinInteractiveDimension + 28;

  @override
  bool represents(LyricLineAction? value) =>
      value == backAction || value == forwardAction;

  @override
  State<_NudgeMenuEntry> createState() => _NudgeMenuEntryState();
}

class _NudgeMenuEntryState extends State<_NudgeMenuEntry> {
  Widget _button({
    required IconData icon,
    required String label,
    required String tooltip,
    required LyricLineAction action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Tooltip(
        message: tooltip,
        // Deliberately not popping the menu route: the whole point is that
        // repeated taps keep working without reopening the overflow menu.
        child: InkWell(
          onTap: () => widget.onNudge(action),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: scheme.onSurface),
                const SizedBox(width: 6),
                Text(label, style: TextStyle(color: scheme.onSurface)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final buttons = Row(
      children: [
        _button(
          icon: Icons.fast_rewind,
          label: '\u2212$kLineNudgeMs ms',
          tooltip: widget.backTooltip,
          action: widget.backAction,
        ),
        _button(
          icon: Icons.fast_forward,
          label: '+$kLineNudgeMs ms',
          tooltip: widget.forwardTooltip,
          action: widget.forwardAction,
        ),
      ],
    );
    final title = widget.title;
    if (title == null) return buttons;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ),
        buttons,
      ],
    );
  }
}
