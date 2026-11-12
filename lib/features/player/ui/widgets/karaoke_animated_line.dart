import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musync/core/id3/models/lyrics.dart';
import 'package:musync/features/player/providers/lyrics_provider.dart';

import 'karaoke_math.dart';

/// The current line, animated — the word being sung sweeps bright left
/// to right, words lift a couple of pixels as they land and settle back,
/// and a held word swells letter by letter.
///
/// Only this line watches the lyric position, so only it rebuilds sixty
/// times a second; the rest of the view rebuilds only when the line or
/// the word changes. Gated on `karaokeAnimations` by the caller — when
/// the option is off, the static karaoke spans render instead and
/// nothing here is ever built.
class AnimatedKaraokeLine extends ConsumerWidget {
  const AnimatedKaraokeLine({
    super.key,
    required this.line,
    required this.wordIndex,
    required this.sungStyle,
    required this.unsungStyle,
    required this.onWordTap,
    this.prefix,
    this.romanization,
    required this.textAlign,
  });

  final LyricLine line;
  final int wordIndex;
  final TextStyle sungStyle;
  final TextStyle unsungStyle;
  final void Function(Duration position) onWordTap;
  final InlineSpan? prefix;
  final InlineSpan? romanization;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position =
        ref.watch(lyricPositionProvider).valueOrNull ?? Duration.zero;
    return Text.rich(
      TextSpan(
        children: [
          ?prefix,
          ...animatedKaraokeSpans(
            line: line,
            wordIndex: wordIndex,
            position: position,
            sungStyle: sungStyle,
            unsungStyle: unsungStyle,
            onWordTap: onWordTap,
          ),
          ?romanization,
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
    );
  }
}

/// The animated spans for a word-timed line at [position]: the word
/// being sung sweeps bright, a word that just ended is still settling
/// back down, and a held word swells letter by letter. Words that are
/// not moving render exactly like the static karaoke spans — plain
/// [TextSpan]s in the sung or unsung style.
///
/// Two simplifications against myspoti, both deliberate: a growing
/// letter's lean and rise are not drawn — a per-letter sideways shift
/// would need a WidgetSpan per letter and would come apart from the
/// word's layout — the swell (size) and the glow (colour) carry the
/// effect on their own. And the sweep is per word, not across the whole
/// line: the spaces between words fill when the next word starts, as
/// they do in the static spans.
@visibleForTesting
List<InlineSpan> animatedKaraokeSpans({
  required LyricLine line,
  required int wordIndex,
  required Duration position,
  required TextStyle sungStyle,
  required TextStyle unsungStyle,
  required void Function(Duration position) onWordTap,
}) {
  final spans = <InlineSpan>[];
  for (var i = 0; i < line.words.length; i++) {
    if (i > 0) {
      // The space between two words takes the style of the word before
      // it; a tap between two words seeks to the start of the word
      // before it — the word just read.
      spans.add(
        TextSpan(
          text: ' ',
          style: i - 1 <= wordIndex ? sungStyle : unsungStyle,
          recognizer: TapGestureRecognizer()
            ..onTap = () => onWordTap(line.words[i - 1].start),
        ),
      );
    }
    final word = line.words[i];
    final isCurrent = i == wordIndex;
    final isGrowing = isCurrent && isGrowingWord(word, position);
    final lift = wordLiftFraction(word: word, position: position);
    // A backing vocal word, sung under the lead line: dimmed and
    // slanted, so the eye reads it as a choir, not as the lead.
    final wordSung = _wordStyle(word, sungStyle);
    final wordUnsung = _wordStyle(word, unsungStyle);

    Widget? wordWidget;
    if (isCurrent && !isGrowing) {
      // The word being sung: two copies in the sung weight, so they are
      // exactly the same width and the clip never drifts — the dim one
      // underneath, the bright one clipped to how much of the word has
      // been sung.
      wordWidget = _sweptWord(
        word: word,
        fraction: wordSweepFraction(word: word, position: position),
        sungStyle: wordSung,
        dimSungStyle:
            wordUnsung.copyWith(fontWeight: wordSung.fontWeight),
      );
    } else if (isGrowing) {
      // A held word, letter by letter: each letter swells and glows in
      // turn. The letters stay in the text flow, so the word never comes
      // apart — the size and the glow carry the move.
      wordWidget = Text.rich(
        TextSpan(children: _growingLetterSpans(word, position, wordSung, wordUnsung)),
      );
    } else if (lift > 0.01) {
      // A word that just ended, still settling back down.
      wordWidget = Text(
        word.text,
        style: i <= wordIndex ? wordSung : wordUnsung,
      );
    }

    if (wordWidget != null) {
      if (lift > 0.01) {
        wordWidget = Transform.translate(
          offset: Offset(0, -lift * karaokeFullLiftPx),
          child: wordWidget,
        );
      }
      spans.add(
        WidgetSpan(
          // Middle, not baseline: the swept word is a Stack, which has
          // no baseline to align on. The words are the same size as the
          // line, so middle alignment is visually exact.
          alignment: PlaceholderAlignment.middle,
          child: GestureDetector(
            onTap: () => onWordTap(word.start),
            child: wordWidget,
          ),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: word.text,
          style: i <= wordIndex ? wordSung : wordUnsung,
          recognizer: TapGestureRecognizer()
            ..onTap = () => onWordTap(word.start),
        ),
      );
    }
  }
  return spans;
}

TextStyle _wordStyle(LyricWord word, TextStyle style) {
  if (!word.isBackground) return style;
  return style.copyWith(
    color: style.color?.withValues(alpha: 0.6),
    fontStyle: FontStyle.italic,
  );
}

/// Two copies of [word] in the sung weight — the dim one underneath,
/// the bright one clipped to [fraction] of the word's width.
Widget _sweptWord({
  required LyricWord word,
  required double fraction,
  required TextStyle sungStyle,
  required TextStyle dimSungStyle,
}) {
  final width = _measureWidth(word.text, sungStyle);
  return SizedBox(
    width: width,
    child: Stack(
      children: [
        Text(word.text, style: dimSungStyle),
        ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: fraction.clamp(0.0, 1.0),
            child: SizedBox(
              width: width,
              child: Text(word.text, style: sungStyle),
            ),
          ),
        ),
      ],
    ),
  );
}

double _measureWidth(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  return painter.width;
}

/// One span per letter of a growing word: the size swells and the
/// colour glows from dim to bright as the letter runs its move.
List<TextSpan> _growingLetterSpans(
  LyricWord word,
  Duration position,
  TextStyle sungStyle,
  TextStyle unsungStyle,
) {
  final baseSize = sungStyle.fontSize ?? 16;
  final spans = <TextSpan>[];
  for (var i = 0; i < word.text.length; i++) {
    final growth = growingLetter(
      word: word,
      charIndex: i,
      position: position,
    );
    spans.add(
      TextSpan(
        text: word.text[i],
        style: sungStyle.copyWith(
          fontSize: baseSize * growth.scale,
          color: Color.lerp(
            unsungStyle.color,
            sungStyle.color,
            growth.bloom.clamp(0.0, 1.0),
          ),
        ),
      ),
    );
  }
  return spans;
}
