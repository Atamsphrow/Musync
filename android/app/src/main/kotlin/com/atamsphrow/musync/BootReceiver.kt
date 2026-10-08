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
            val dayMillis = 24L * 60 * 60 * 1000
            val stale = mutableListOf<String>()

            for ((key, value) in prefs.all) {
                if (!key.startsWith("trigger_")) continue
                val id = key.removePrefix("trigger_")
                var trigger = value as? Long ?: continue
                val daily = prefs.getBoolean("daily_$id", false)
                if (trigger <= now) {
                    if (!daily) {
                        stale.add(id)
                        continue
                    }
                    while (trigger <= now) trigger += dayMillis
                    prefs.edit().putLong("trigger_$id", trigger).apply()
                }
                val rc = prefs.getInt("rc_$id", 0)
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
                alarmManager.setAlarmClock(
                    AlarmManager.AlarmClockInfo(trigger, showPending), pending,
                )
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
