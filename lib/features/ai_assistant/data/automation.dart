/// Automatisations de l'assistant : actions planifiées et déclencheur écouteurs.
///
/// Deux niveaux, documentés aussi dans le prompt système :
/// - `schedule_action` (T1) : « dans X minutes », minuteur en mémoire, meurt
///   avec l'app ;
/// - ici : `schedule_once` / `schedule_daily`, à heure précise, via une
///   alarme Android (`setAlarmClock`) — survit à la fermeture de l'app et au
///   redémarrage du téléphone.
///
/// Tout le texte destiné à l'utilisateur est en français.
library;

/// Une action planifiée : un outil de l'assistant à exécuter à une heure
/// précise.
///
/// [daily] vrai = tous les jours à [hour]:[minute] ; faux = une seule fois à
/// [fireAtMillis]. [fireAtMillis] est la PROCHAINE exécution (epoch ms, heure
/// locale) — c'est ce que le côté natif réarme au boot, sans recalcul.
class ScheduledAction {
  final String id;
  final bool daily;
  final int fireAtMillis;
  final int hour;
  final int minute;
  final String toolName;
  final Map<String, Object?> args;
  final String label;
  final bool enabled;

  const ScheduledAction({
    required this.id,
    required this.daily,
    required this.fireAtMillis,
    required this.hour,
    required this.minute,
    required this.toolName,
    this.args = const {},
    required this.label,
    this.enabled = true,
  });

  /// La prochaine occurrence de [hour]:[minute] strictement après [from].
  static int nextDailyFire(int hour, int minute, DateTime from) {
    var candidate = DateTime(from.year, from.month, from.day, hour, minute);
    if (!candidate.isAfter(from)) {
      candidate = candidate.add(const Duration(days: 1));
    }
    return candidate.millisecondsSinceEpoch;
  }

  /// « Tous les jours à 22:00 » / « Le ven. 9 oct. à 07:00 ».
  String describeSchedule() {
    final hh = hour.toString().padLeft(2, '0');
    final mm = minute.toString().padLeft(2, '0');
    if (daily) return 'Tous les jours à $hh:$mm';
    final at = DateTime.fromMillisecondsSinceEpoch(fireAtMillis);
    return 'Le ${_frenchDay(at)} à $hh:$mm';
  }

  static String _frenchDay(DateTime d) {
    const days = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];
    const months = [
      'janv', 'févr', 'mars', 'avr', 'mai', 'juin',
      'juil', 'août', 'sept', 'oct', 'nov', 'déc',
    ];
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }

  ScheduledAction copyWith({int? fireAtMillis, bool? enabled}) =>
      ScheduledAction(
        id: id,
        daily: daily,
        fireAtMillis: fireAtMillis ?? this.fireAtMillis,
        hour: hour,
        minute: minute,
        toolName: toolName,
        args: args,
        label: label,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'daily': daily,
        'fireAtMillis': fireAtMillis,
        'hour': hour,
        'minute': minute,
        'toolName': toolName,
        'args': args,
        'label': label,
        'enabled': enabled,
      };

  static ScheduledAction? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      final args = json['args'];
      return ScheduledAction(
        id: json['id'] as String,
        daily: json['daily'] as bool,
        fireAtMillis: (json['fireAtMillis'] as num).toInt(),
        hour: (json['hour'] as num).toInt(),
        minute: (json['minute'] as num).toInt(),
        toolName: json['toolName'] as String,
        args: args is Map ? args.cast<String, Object?>() : const {},
        label: json['label'] as String,
        enabled: json['enabled'] as bool? ?? true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Déclencheur « écouteurs branchés » : l'outil à exécuter quand un casque ou
/// des écouteurs (jack, USB ou Bluetooth) sont connectés.
///
/// Null = désactivé. Ne se déclenche que si rien ne joue déjà — brancher ses
/// écouteurs en pleine lecture ne doit pas changer de file.
class HeadphoneTrigger {
  final String toolName;
  final Map<String, Object?> args;
  final String label;

  const HeadphoneTrigger({
    required this.toolName,
    this.args = const {},
    required this.label,
  });

  Map<String, Object?> toJson() => {
        'toolName': toolName,
        'args': args,
        'label': label,
      };

  static HeadphoneTrigger? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      final args = json['args'];
      return HeadphoneTrigger(
        toolName: json['toolName'] as String,
        args: args is Map ? args.cast<String, Object?>() : const {},
        label: json['label'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}
