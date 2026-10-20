/// Courbe du fondu de volume du réveil : logique pure, testable sans player.
///
/// Le réveil démarre la lecture à [startVolume] puis monte jusqu'au volume
/// normal en [duration]. La courbe est quadratique, pas linéaire : l'oreille
/// perçoit le volume de façon logarithmique, donc un fondu linéaire donne
/// l'impression que rien ne se passe pendant la première moitié puis que ça
/// explose à la fin.
abstract final class VolumeFade {
  /// Volume de départ du fondu, en fraction du volume cible.
  static const double startVolume = 0.05;

  /// Durée du fondu de réveil : 90 s. Intégrée, pas un réglage — le
  /// réveil monte en douceur par défaut, sans paramètre (demande
  /// d'Atamsphrow, 2026-10-21).
  static const Duration alarmDuration = Duration(seconds: 90);

  /// Volume (0.0–1.0, fraction du volume cible) à [elapsed] dans un fondu de
  /// [duration].
  static double volumeAt(Duration elapsed, Duration duration) {
    if (duration <= Duration.zero) return 1.0;
    final t = (elapsed.inMilliseconds / duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    if (t <= 0) return startVolume;
    if (t >= 1) return 1.0;
    return startVolume + (1 - startVolume) * t * t;
  }
}
