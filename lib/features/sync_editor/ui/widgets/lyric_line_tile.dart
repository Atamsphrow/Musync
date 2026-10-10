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

/// Action chosen from a line's overflow menu.
enum LyricLineAction {
  editText,
  nudgeBack,
  nudgeForward,

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
  /// Three states, and they must not be confused with each other:
  ///
  ///  * a real time — the line is placed;
  ///  * `Duration.zero` — not stamped *yet*; the line is waiting its turn;
  ///  * `null` — deliberately stripped, a structural marker like `[Refrain]`
  ///    that will be left out of SYLT.
  ///
  /// The middle one used to stand in for both, which meant a marker the user
  /// had cleared looked identical to a line they still had to time.
  final Duration? timestamp;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _TimestampChip({
    required this.timestamp,
    required this.onTap,
    required this.onLongPress,
  });

  bool get _isCleared => timestamp == null;
  bool get _isPending => timestamp == Duration.zero;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPlaced = !_isCleared && !_isPending;

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
                Duration.zero => '--:--.--',
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
  const _NudgeMenuEntry({required this.onNudge});

  final ValueChanged<LyricLineAction> onNudge;

  @override
  double get height => kMinInteractiveDimension;

  @override
  bool represents(LyricLineAction? value) =>
      value == LyricLineAction.nudgeBack ||
      value == LyricLineAction.nudgeForward;

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
    return Row(
      children: [
        _button(
          icon: Icons.fast_rewind,
          label: '\u2212$kLineNudgeMs ms',
          tooltip: _nudgeBackLabel,
          action: LyricLineAction.nudgeBack,
        ),
        _button(
          icon: Icons.fast_forward,
          label: '+$kLineNudgeMs ms',
          tooltip: _nudgeForwardLabel,
          action: LyricLineAction.nudgeForward,
        ),
      ],
    );
  }
}
