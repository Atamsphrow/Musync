package com.atamsphrow.musync

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// Réarme les automatisations après un redémarrage : les alarmes
/// `AlarmManager` ne survivent pas au reboot.
///
/// Ne parse jamais le JSON de Dart : il relit le miroir que Dart pousse dans
/// les SharedPreferences à chaque changement (`syncAlarms`). Les quotidiennes
/// dont l'heure est passée pendant l'extinction sont avancées au prochain
/// créneau ; les « une fois » périmées sont abandonnées.
///
/// Un boot raté ne bloque jamais le démarrage : Dart resynchronise tout à la
/// prochaine ouverture de l'app, qui est la source de vérité.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        try {
            val prefs = context.getSharedPreferences(
                MainActivity.SCHEDULER_PREFS, Context.MODE_PRIVATE,
            )
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val now = System.currentTimeMillis()
            val stale = mutableListOf<String>()

            for ((key, value) in prefs.all) {
                if (!key.startsWith("trigger_")) continue
                val id = key.removePrefix("trigger_")
                var trigger = value as? Long ?: continue
                // Lectures protégées une par une : getBoolean/getInt lèvent
                // ClassCastException quand le type stocké ne correspond pas,
                // et sans ça une seule pref corrompue tuait toute la boucle
                // (le try global ne servait qu'à abandonner le boot).
                val daily = try {
                    prefs.getBoolean("daily_$id", false)
                } catch (_: ClassCastException) {
                    false
                }
                if (trigger <= now) {
                    if (!daily) {
                        stale.add(id)
                        continue
                    }
                    // Jour calendaire, pas 24 h absolues : ajouter des
                    // millisecondes décale l'heure murale d'1 h aux
                    // changements d'heure (DST). `Calendar.add(DAY_OF_MONTH)`
                    // garde l'heure locale — cohérent avec `nextDailyFire`
                    // côté Dart.
                    val calendar = java.util.Calendar.getInstance().apply {
                        timeInMillis = trigger
                    }
                    while (trigger <= now) {
                        calendar.add(java.util.Calendar.DAY_OF_MONTH, 1)
                        trigger = calendar.timeInMillis
                    }
                    prefs.edit().putLong("trigger_$id", trigger).apply()
                }
                val rc = try {
                    prefs.getInt("rc_$id", 0)
                } catch (_: ClassCastException) {
                    0
                }
                if (rc == 0) continue
                val alarmIntent = Intent(context, MainActivity::class.java).apply {
                    action = "com.atamsphrow.musync.SCHEDULED_ACTION"
                    putExtra("musync_scheduled_action", id)
                }
                val pending = PendingIntent.getActivity(
                    context, rc, alarmIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val showIntent =
                    context.packageManager.getLaunchIntentForPackage(context.packageName)
                val showPending = showIntent?.let {
                    PendingIntent.getActivity(
                        context, 0, it, PendingIntent.FLAG_IMMUTABLE,
                    )
                }
                // Per alarm, not around the whole loop: one failure
                // (the exact-alarm permission revoked since this one
                // was armed, say) must not starve the alarms after it.
                // Dart re-syncs everything at the next launch anyway.
                try {
                    alarmManager.setAlarmClock(
                        AlarmManager.AlarmClockInfo(trigger, showPending), pending,
                    )
                } catch (_: Exception) {
                    // Skipped on purpose — see above.
                }
            }

            if (stale.isNotEmpty()) {
                val edit = prefs.edit()
                for (id in stale) {
                    edit.remove("rc_$id").remove("trigger_$id")
                        .remove("label_$id").remove("daily_$id")
                }
                edit.apply()
            }
        } catch (_: Exception) {
            // Voir le docstring : un boot raté ne bloque rien.
        }
    }
}
