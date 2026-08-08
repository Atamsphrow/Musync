/// `m:ss`, or `h:mm:ss` once a track runs past the hour.
///
/// Leading zeros are dropped from the largest unit — `3:07`, not `03:07` — the
/// way every music player writes a track length.
String formatClock(Duration duration) {
  final total = duration.isNegative ? Duration.zero : duration;
  final hours = total.inHours;
  final minutes = total.inMinutes.remainder(60);
  final seconds = total.inSeconds.remainder(60);

  final ss = seconds.toString().padLeft(2, '0');
  if (hours == 0) return '$minutes:$ss';
  return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
}
