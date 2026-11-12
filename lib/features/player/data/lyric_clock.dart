/// A monotonic position for the lyrics display.
///
/// `AudioPlayerService.position` is just_audio's own extrapolated getter —
/// smooth and speed-aware — but every new platform event re-anchors the
/// extrapolation, and the re-anchored position can sit a few milliseconds
/// *behind* the previous one. At a line boundary that flicks the current
/// line (or word) back for a frame.
///
/// This clock is the small guard that fixes exactly that, and nothing more.
/// It is deliberately NOT myspoti's full driven clock: there is no rate to
/// learn here (just_audio already extrapolates at the right speed, and the
/// app exposes no speed setting), no catch-up, no smoothstep. Three rules:
///
/// - forward is followed immediately — the audio really is there, and
///   holding the line back would be wrong;
/// - a small step back is absorbed — the last emitted position is repeated
///   until the raw position catches up with it;
/// - a big step back is a seek (or a loop restart, which resets the position
///   to zero on the same track) and is followed at once.
///
/// The seek boundary is a magnitude threshold, not the service's private
/// seek record: exposing that record would couple the display to an
/// internal debounce detail, and the record is set when the seek is *sent*,
/// before the position has actually moved — so a clock driven by it would
/// still need a window. The cost of the threshold is bounded: a tap on a
/// line less than the threshold behind the current position leaves the old
/// line lit for at most the jump (under 800 ms), then the raw position
/// catches up on its own. Taps almost always land seconds away, and the
/// audio itself is never delayed — only the highlight.
///
/// One instance per track: the line and word providers each own one and are
/// rebuilt on every song change, so a fresh clock starts with the new track.
/// The compensation offset is added *after* the clock: dragging the slider
/// must move the lines at once, not be absorbed as jitter.
class LyricClock {
  /// A step back larger than this is a seek, not jitter. myspoti's
  /// `SEEK_JUMP_MS` uses the same 800 ms for the same judgement.
  static const Duration seekJumpThreshold = Duration(milliseconds: 800);

  Duration? _emitted;

  /// The position the lyrics should be read at, given the raw [position]
  /// just sampled from the player.
  Duration tick(Duration position) {
    final last = _emitted;
    if (last == null) {
      _emitted = position;
      return position;
    }
    if (position >= last) {
      _emitted = position;
      return position;
    }
    // A step back: a seek (or a loop restart) when it is big, jitter
    // when it is small. Jitter is absorbed by repeating the last
    // emitted position; the raw position catches up within the jump.
    if (last - position > seekJumpThreshold) {
      _emitted = position;
      return position;
    }
    return last;
  }
}
