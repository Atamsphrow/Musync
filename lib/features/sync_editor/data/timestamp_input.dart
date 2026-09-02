/// Reads a timestamp the user typed.
///
/// Lifted out of the dialog that used it. It was a `static` on a private
/// `State`, which put the one piece of parsing logic in the sync editor
/// somewhere no test could reach — and parsing what someone types is exactly
/// the kind of thing that wants pinning down by example rather than by hand.
library;

abstract final class TimestampInput {
  /// `mm:ss.cc`, `mm:ss`, `ss.cc` or bare seconds. A comma reads as a decimal
  /// point.
  ///
  /// Forgiving on purpose. The alternative is refusing `1:23` over a missing
  /// leading zero, which is worse than guessing correctly. Seconds above 59 are
  /// allowed too, so `83` means 1:23 rather than an error.
  ///
  /// Returns null for anything it cannot read, which the caller shows as a
  /// format hint.
  static Duration? parse(String raw) {
    final text = raw.trim().replaceAll(',', '.');
    if (text.isEmpty) return null;

    final match = RegExp(
      r'^(?:(\d+):)?(\d+)(?:\.(\d{1,3}))?$',
    ).firstMatch(text);
    if (match == null) return null;

    // `tryParse` throughout, including for the seconds. The group is `\d+` with
    // no upper bound, so a hand resting on a digit key produces a number too
    // large for a 64-bit int — and `int.parse` answers that with an exception,
    // thrown out of a text field where nothing is waiting for it. An unreadable
    // number is a rejected entry, not a crash.
    final minutes = int.tryParse(match.group(1) ?? '0');
    final seconds = int.tryParse(match.group(2)!);
    if (minutes == null || seconds == null) return null;

    final fraction = match.group(3);
    return Duration(
      minutes: minutes,
      seconds: seconds,
      // ".4" is four tenths, ".45" forty-five hundredths — pad before parsing,
      // or both would come out as 4 ms and 45 ms.
      milliseconds: fraction == null
          ? 0
          : int.tryParse(fraction.padRight(3, '0')) ?? 0,
    );
  }
}
