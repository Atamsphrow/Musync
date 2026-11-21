package com.atamsphrow.musync

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.RemoteViews

/// Home-screen widget: the playing track and its cover, Previous ·
/// Play/Pause · Next.
///
/// The buttons do not go through audio_service's media-button receiver:
/// pressed with Musync's process dead, that path starts the playback
/// service with nothing queued, and a foreground service that never shows
/// its notification is killed by Android — with Musync. Instead they come
/// here, and are forwarded to Dart only while a live player listens
/// ([WidgetBridge.isLive]). Otherwise the widget shows « open the app »
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
        if (channel == null || !WidgetBridge.isLive) {
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

        /// Longest side of the cover kept for the widget, in pixels: the
        /// 40 dp slot at the densest screens, with room to spare. Sent with
        /// every widget update, so it is kept small.
        private const val ARTWORK_MAX_PX = 192

        /// The playing track's cover, decoded once per cover. In memory
        /// only: it is drawn only while a live player feeds the widget
        /// (the same process); otherwise the widget shows its « open the
        /// app » face, without a cover.
        @Volatile
        private var artwork: Bitmap? = null

        fun setArtwork(bytes: ByteArray?) {
            artwork = bytes?.let { decodeArtwork(it) }
        }

        /// [bytes] decoded at about [ARTWORK_MAX_PX]: subsampled while
        /// decoding (a 1024 px cover never sits in memory at full size),
        /// then scaled to fit. Null for bytes that are not an image.
        private fun decodeArtwork(bytes: ByteArray): Bitmap? = try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= ARTWORK_MAX_PX &&
                bounds.outHeight / (sample * 2) >= ARTWORK_MAX_PX
            ) {
                sample *= 2
            }
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            if (decoded == null) {
                null
            } else {
                val side = maxOf(decoded.width, decoded.height)
                if (side <= ARTWORK_MAX_PX) {
                    decoded
                } else {
                    val scale = ARTWORK_MAX_PX.toFloat() / side
                    Bitmap.createScaledBitmap(
                        decoded,
                        maxOf(1, (decoded.width * scale).toInt()),
                        maxOf(1, (decoded.height * scale).toInt()),
                        true,
                    ).also { if (it !== decoded) decoded.recycle() }
                }
            }
        } catch (error: Exception) {
            null
        } catch (error: OutOfMemoryError) {
            null
        }

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
            val live = WidgetBridge.isLive
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
            // The cover in place of the app icon, while it plays.
            val cover = if (controls) artwork else null
            if (cover != null) {
                views.setImageViewBitmap(R.id.widget_art, cover)
                views.setViewVisibility(R.id.widget_art, View.VISIBLE)
                views.setViewVisibility(R.id.widget_icon, View.GONE)
            } else {
                views.setViewVisibility(R.id.widget_art, View.GONE)
                views.setViewVisibility(R.id.widget_icon, View.VISIBLE)
            }

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

        /// Request code of the « open the app » PendingIntent. Never 0:
        /// [launchIntent] filterEquals the launcher intent the batch-done
        /// notification and the alarm clock use, and on a shared code each
        /// FLAG_UPDATE_CURRENT widget refresh replaced their extras — the
        /// notification then opened the library, not the batch review.
        private const val OPEN_APP_REQUEST_CODE = 0x4D57

        private fun openAppIntent(context: Context): PendingIntent =
            PendingIntent.getActivity(
                context,
                OPEN_APP_REQUEST_CODE,
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
