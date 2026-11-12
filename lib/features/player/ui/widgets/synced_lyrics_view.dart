import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';
import 'package:musync/features/player/providers/player_provider.dart';
import 'package:musync/features/player/ui/widgets/karaoke_animated_line.dart';
import 'package:musync/features/player/ui/widgets/karaoke_separators.dart';
import 'package:musync/features/player/ui/widgets/nudge_line_sheet.dart';
import 'package:musync/features/settings/data/lyrics_appearance.dart';
import 'package:musync/features/settings/providers/lyrics_appearance_provider.dart';
import 'package:musync/features/library/data/models/song.dart';

/// The spans for a word-timed line: words already sung (including the
/// current one) in [sungStyle], words still to come in [unsungStyle] —
/// the classic karaoke sweep. A [wordIndex] of -1 means "none sung yet",
/// so a line that is not current renders all its words unsung.
///
/// Spaces between words take the style of the word before them; they carry
/// no glyph, so the choice is invisible either way. The styles are explicit
/// on every span, so a word change switches instantly — the 120 ms
/// cross-fade of the line around it does not apply here, on purpose: a
/// fade per word would blur the timing on fast lyrics.
///
/// When [onWordTap] is given, every word seeks to its own start when
/// tapped, and a tap between two words seeks to the start of the word
/// before it — the word just read, as in myspoti's `startAtChar`. The
/// span recognizer wins the hit test over the line's InkWell, so a word
/// tap never also seeks to the line.
@visibleForTesting
List<TextSpan> karaokeWordSpans({
  required LyricLine line,
  required int wordIndex,
  required TextStyle sungStyle,
  required TextStyle unsungStyle,
  void Function(Duration position)? onWordTap,
}) {
  final spans = <TextSpan>[];
  final seps = karaokeWordSeparators(line);
  for (var i = 0; i < line.words.length; i++) {
    if (i > 0) {
      final sep = seps == null ? ' ' : seps[i - 1];
      if (sep.isNotEmpty) {
        spans.add(
          TextSpan(
            text: sep,
            style: i - 1 <= wordIndex ? sungStyle : unsungStyle,
            recognizer: onWordTap == null
                ? null
                : (TapGestureRecognizer()
                  ..onTap = () => onWordTap(line.words[i - 1].start)),
          ),
        );
      }
    }
    final word = line.words[i];
    var style = i <= wordIndex ? sungStyle : unsungStyle;
    // A backing vocal word, sung under the lead line: dimmed and
    // slanted, so the eye reads it as a choir, not as the lead.
    if (word.isBackground) {
      style = style.copyWith(
        color: style.color?.withValues(alpha: 0.6),
        fontStyle: FontStyle.italic,
      );
    }
    spans.add(
      TextSpan(
        text: word.text,
        style: style,
        recognizer: onWordTap == null
            ? null
            : (TapGestureRecognizer()
              ..onTap = () => onWordTap(word.start)),
      ),
    );
  }
  return spans;
}

/// The voice label for a line in a duet, or null when the song is not a
/// duet or the line's singer is unknown. Only the second singer is
/// marked — the first is the default voice, and a line sung together
/// needs no label either.
String? voicePrefix(LyricLine line, bool hasDuet) =>
    hasDuet && line.voice == 2 ? 'V2' : null;

/// The romanization under a line, or null when the line has none to
/// show: the setting is off, the source gave none, or it is identical
/// to the line itself. Same words, another alphabet — never a
/// replacement for the line.
TextSpan? romanizationSpan(
  LyricLine line,
  LyricsAppearance appearance,
  Color dimColor,
) {
  final romanization = line.romanization;
  if (!appearance.showRomanization) return null;
  if (romanization == null || romanization.trim().isEmpty) return null;
  if (romanization == line.text) return null;
  return TextSpan(
    text: '\n$romanization',
    style: TextStyle(
      fontSize: 12 * appearance.fontScale,
      color: dimColor,
      fontStyle: FontStyle.italic,
      fontWeight: FontWeight.w400,
    ),
  );
}

/// Karaoke-style lyrics: the active line is highlighted and kept centered
/// while the track plays. Tapping a line seeks to it.
class SyncedLyricsView extends ConsumerStatefulWidget {
  final SyncedLyrics lyrics;
  final VoidCallback? onSearchOnline;

  /// The currently playing song. Required for the long-press action, which
  /// nudges the pressed line's timing straight in the file. Null only when the
  /// view is shown without a player behind it (preview, etc).
  final Song? song;

  /// The track's plain lyrics, passed through untouched when the long-press
  /// nudge rewrites the timings.
  final UnsyncedLyrics? unsynced;

  const SyncedLyricsView({
    super.key,
    required this.lyrics,
    this.onSearchOnline,
    this.song,
    this.unsynced,
  });

  @override
  ConsumerState<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

/// Builds the line style from the user's appearance settings. The system
/// serif keeps the APK free of a bundled font; on Android it resolves to
/// Noto Serif Italic.
TextStyle _lyricsTextStyle(TextStyle? base, LyricsAppearance appearance) {
  var style = base!;
  if (appearance.fontStyle == LyricsFontStyle.stylized) {
    style = style.copyWith(fontFamily: 'serif');
  }
  if (appearance.italic) {
    style = style.copyWith(fontStyle: FontStyle.italic);
  }
  return style.copyWith(fontSize: (style.fontSize ?? 16) * appearance.fontScale);
}

class _SyncedLyricsViewState extends ConsumerState<SyncedLyricsView> {
  // Measuring every line would mean laying the whole song out up front, so
  // lines are given a fixed extent instead — that also makes centering exact
  // rather than the running approximation it would otherwise be.
  static const double _lineExtent = 56;

  final ScrollController _scrollController = ScrollController();
  int? _lastCenteredIndex;
  // A build schedules at most one post-frame centering: without the flag,
  // every rebuild re-scheduled one while the previous was still pending.
  bool _centerScheduled = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _centerLine(int index, double viewportHeight) {
    if (_lastCenteredIndex == index) return;
    if (!_scrollController.hasClients) return;
    _lastCenteredIndex = index;

    // No end padding: the list is a plain list, so the first line rests at
    // the very top and the last at the very bottom — never floating mid-screen.
    // Centring a line's midpoint means scrolling to:
    //
    //     index * extent + extent / 2 - viewportHeight / 2
    //
    // clamped to what the list can actually scroll.
    final target =
        (index * _lineExtent) + (_lineExtent / 2) - (viewportHeight / 2);

    // One fixed, quick glide per line: 250 ms, ease-out. Measured
    // frame-by-frame on Musicolet's lyrics view: the step starts fast and
    // settles softly, which is ease-out, not ease-in-out.
    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void didUpdateWidget(covariant SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new song (or retimed lyrics) must not inherit the old scroll anchor:
    // the next line change re-centres from wherever the list happens to be.
    if (oldWidget.lyrics != widget.lyrics) _lastCenteredIndex = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currentIndex = ref.watch(currentLineIndexProvider).valueOrNull;
    final currentWord = ref.watch(currentWordIndexProvider).valueOrNull;
    final appearance = ref.watch(lyricsAppearanceProvider);
    final textAlign = switch (appearance.textAlign) {
      LyricsTextAlign.left => TextAlign.left,
      LyricsTextAlign.center => TextAlign.center,
      LyricsTextAlign.right => TextAlign.right,
    };

    if (widget.lyrics.isEmpty) {
      return _EmptyLyrics(onSearchOnline: widget.onSearchOnline);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (currentIndex != null) {
          if (!_centerScheduled) {
            _centerScheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _centerScheduled = false;
              if (mounted) _centerLine(currentIndex, constraints.maxHeight);
            });
          }
        }

        return ListView.builder(
          controller: _scrollController,
          itemCount: widget.lyrics.length,
          itemExtent: _lineExtent,
          itemBuilder: (context, index) {
            final line = widget.lyrics.lines[index];
            final isCurrent = index == currentIndex;

            // The active line is bold in the chosen color, everything else
            // the same dim grey — no past/future split.
            final Color color = isCurrent
                ? lyricsActiveColor(context, appearance)
                : scheme.onSurfaceVariant.withValues(alpha: 0.55);
            final dimColor =
                scheme.onSurfaceVariant.withValues(alpha: 0.55);

            // Karaoke: when a line carries word timings, its words are
            // rendered as spans — the current line's sung split, every
            // other line all unsung — so a tap on any word seeks to it,
            // current line or not. The sung split itself only applies
            // to the current line: the two providers sample
            // independently, and a one-frame disagreement must light
            // nothing, not the wrong line's word.
            //
            // Guarded on the coverage: the words must cover the line's
            // text exactly — a syllable split (« nev » + « er » for
            // « never ») is fine, the separators come from the text
            // itself. A source whose words disagree with its line text
            // falls back to the plain line — no karaoke is better than
            // karaoke showing different words.
            final wordIndex = isCurrent && currentWord?.lineIndex == index
                ? currentWord?.wordIndex ?? -1
                : -1;
            final showWords =
                line.hasWordTimings && karaokeWordSeparators(line) != null;
            // In a duet, the second singer's lines carry a small marker.
            final prefix = voicePrefix(line, widget.lyrics.hasDuet);
            // The romanization under the line, when the line has one.
            final romanization =
                romanizationSpan(line, appearance, dimColor);

            // The sung and unsung word styles, shared by the static and
            // the animated rendering of the line.
            final sungStyle = _lyricsTextStyle(
              textTheme.bodyLarge,
              appearance,
            ).copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            );
            final unsungStyle = _lyricsTextStyle(
              textTheme.bodyLarge,
              appearance,
            ).copyWith(
              color: dimColor,
              fontWeight: FontWeight.w400,
            );
            final prefixSpan = prefix == null
                ? null
                : TextSpan(
                    text: '$prefix · ',
                    style: TextStyle(
                      fontSize: 12,
                      color: dimColor,
                      fontWeight: FontWeight.w600,
                    ),
                  );
            // The animated rendering applies only to the current line,
            // only when the option is on, and only when the line carries
            // word timings — every other line renders exactly as before.
            final Widget lineChild;
            if (showWords &&
                isCurrent &&
                appearance.karaokeAnimations) {
              lineChild = AnimatedKaraokeLine(
                line: line,
                wordIndex: wordIndex,
                sungStyle: sungStyle,
                unsungStyle: unsungStyle,
                onWordTap: (position) =>
                    ref.read(audioPlayerServiceProvider).seekTo(position),
                prefix: prefixSpan,
                romanization: romanization,
                textAlign: textAlign,
              );
            } else if (showWords) {
              lineChild = Text.rich(
                TextSpan(
                  children: [
                    ?prefixSpan,
                    ...karaokeWordSpans(
                      line: line,
                      wordIndex: wordIndex,
                      onWordTap: (position) => ref
                          .read(audioPlayerServiceProvider)
                          .seekTo(position),
                      sungStyle: sungStyle,
                      unsungStyle: unsungStyle,
                    ),
                    ?romanization,
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
              );
            } else {
              lineChild = Text.rich(
                TextSpan(
                  children: [
                    ?prefixSpan,
                    TextSpan(text: line.text),
                    ?romanization,
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
              );
            }

            return InkWell(
              // Non-null: this view renders SyncedLyrics, which is timed-only.
              onTap: () =>
                  ref.read(audioPlayerServiceProvider).seekTo(line.timestamp!),
              // Long-press: nudge this line's timing directly (±100 ms),
              // without opening the full sync editor. The editor stays
              // available from the player's "Ajuster la synchronisation"
              // menu entry.
              onLongPress: widget.song == null
                  ? null
                  : () => showNudgeLineSheet(
                        context,
                        ref,
                        filePath: widget.song!.filePath,
                        synced: widget.lyrics,
                        unsynced: widget.unsynced,
                        index: index,
                      ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Center(
                  child: AnimatedDefaultTextStyle(
                    // Short on purpose, and it is the other half of T22: the
                    // detection is now exact to the frame, but a quarter-second
                    // cross-fade on the colour and the weight still reads as
                    // lag. The scroll below keeps its 250 ms — that one is
                    // motion, and motion is allowed to be smooth.
                    duration: const Duration(milliseconds: 120),
                    style: _lyricsTextStyle(textTheme.bodyLarge, appearance)
                        .copyWith(
                      color: color,
                      fontWeight:
                          isCurrent ? FontWeight.w700 : FontWeight.w400,
                    ),
                    textAlign: textAlign,
                    child: lineChild,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _EmptyLyrics extends StatelessWidget {
  final VoidCallback? onSearchOnline;

  const _EmptyLyrics({this.onSearchOnline});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lyrics_outlined,
            size: 56,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Aucune parole pour ce morceau',
            style: textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (onSearchOnline != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onSearchOnline,
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Rechercher en ligne'),
            ),
          ],
        ],
      ),
    );
  }
}
