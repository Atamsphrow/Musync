package com.atamsphrow.musync

import android.content.Context
import io.flutter.plugin.common.MethodChannel

/// The link between the home-screen widget and the Dart player.
///
/// Dart pushes what is playing (`update`); the widget's buttons call back
/// into Dart (`action`, handled by `HomeWidgetBridge` on the Dart side).
/// Attached by MainActivity on the engine that audio_service keeps alive
/// with the playback, so it survives the UI being closed while music plays.
///
/// [channel] is null in a process that has not attached Dart yet — after
/// Android killed Musync, typically. The widget then offers to open the app
/// rather than buttons with no player behind them.
object WidgetBridge {
    const val CHANNEL = "com.atamsphrow.musync/widget"

    @Volatile
    var channel: MethodChannel? = null
        private set

    fun attach(channel: MethodChannel, context: Context) {
        val appContext = context.applicationContext
        this.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    MusyncWidgetProvider.saveState(
                        appContext,
                        title = call.argument<String>("title"),
                        artist = call.argument<String>("artist"),
                        playing = call.argument<Boolean>("playing") ?: false,
                    )
                    MusyncWidgetProvider.refreshAll(appContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // The buttons switch from « open the app » to live controls.
        MusyncWidgetProvider.refreshAll(appContext)
    }
}
