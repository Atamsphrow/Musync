package com.atamsphrow.musync

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.widget.RemoteViews

/// Home-screen widget: the playing track, Previous · Play/Pause · Next.
///
/// The buttons do not go through audio_service's media-button receiver:
/// pressed with Musync's process dead, that path starts the playback
/// service with nothing queued, and a foreground service that never shows
/// its notification is killed by Android — with Musync. Instead they come
/// here, and are forwarded to Dart only while a live player listens
/// ([WidgetBridge.channel]). Otherwise the widget shows « open the app »
/// and every tap opens it, which is the one safe way to get a player back.
class MusyncWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val views = buildViews(context)
        for (id in appWidgetIds) appWidgetManager.updateAppWidget(id, views)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val action = when (intent.action) {
            ACTION_PREVIOUS -> "previous"
            ACTION_TOGGLE -> "toggle"
            ACTION_NEXT -> "next"
            else -> return
        }
        val channel = WidgetBridge.channel
        if (channel == null) {
            // A tap that outlived the process that drew the buttons: show the
            // « open the app » face, and try to open it.
            refreshAll(context)
            openApp(context)
            return
        }
        Handler(Looper.getMainLooper()).post {
            channel.invokeMethod("action", action)
        }
    }

    companion object {
        const val ACTION_PREVIOUS = "com.atamsphrow.musync.widget.PREVIOUS"
        const val ACTION_TOGGLE = "com.atamsphrow.musync.widget.TOGGLE"
        const val ACTION_NEXT = "com.atamsphrow.musync.widget.NEXT"

        private const val PREFS = "musync_widget"
        private const val KEY_TITLE = "title"
        private const val KEY_ARTIST = "artist"
        private const val KEY_PLAYING = "playing"

        fun saveState(
            context: Context,
            title: String?,
            artist: String?,
            playing: Boolean,
        ) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_TITLE, title)
                .putString(KEY_ARTIST, artist)
                .putBoolean(KEY_PLAYING, playing)
                .apply()
        }

        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, MusyncWidgetProvider::class.java),
            )
            if (ids.isEmpty()) return
            manager.updateAppWidget(ids, buildViews(context))
        }

        private fun buildViews(context: Context): RemoteViews {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val live = WidgetBridge.channel != null
            val title = prefs.getString(KEY_TITLE, null)
            val artist = prefs.getString(KEY_ARTIST, null)
            val controls = live && title != null
            val playing = controls && prefs.getBoolean(KEY_PLAYING, false)

            val views = RemoteViews(context.packageName, R.layout.musync_widget)
            views.setTextViewText(
                R.id.widget_title,
                if (controls) title else "Musync",
            )
            views.setTextViewText(
                R.id.widget_artist,
                if (controls) artist ?: "" else "Touchez pour ouvrir",
            )
            views.setImageViewResource(
                R.id.widget_play,
                if (playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
            )
            views.setContentDescription(
                R.id.widget_play,
                if (playing) "Pause" else "Lecture",
            )

            val open = openAppIntent(context)
            views.setOnClickPendingIntent(R.id.widget_root, open)
            if (controls) {
                views.setOnClickPendingIntent(
                    R.id.widget_previous,
                    broadcast(context, ACTION_PREVIOUS, 1),
                )
                views.setOnClickPendingIntent(
                    R.id.widget_play,
                    broadcast(context, ACTION_TOGGLE, 2),
                )
                views.setOnClickPendingIntent(
                    R.id.widget_next,
                    broadcast(context, ACTION_NEXT, 3),
                )
            } else {
                // No live player: every button opens the app.
                views.setOnClickPendingIntent(R.id.widget_previous, open)
                views.setOnClickPendingIntent(R.id.widget_play, open)
                views.setOnClickPendingIntent(R.id.widget_next, open)
            }
            return views
        }

        private fun broadcast(context: Context, action: String, code: Int): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                code,
                Intent(context, MusyncWidgetProvider::class.java).setAction(action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        private fun launchIntent(context: Context): Intent =
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED,
                )

        private fun openAppIntent(context: Context): PendingIntent =
            PendingIntent.getActivity(
                context,
                0,
                launchIntent(context),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        private fun openApp(context: Context) {
            try {
                context.startActivity(launchIntent(context))
            } catch (error: Exception) {
                // Background activity starts can be refused; the widget now
                // shows « Touchez pour ouvrir », whose tap is always allowed.
            }
        }
    }
}
