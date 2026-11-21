package com.atamsphrow.musync

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// The link between the home-screen widget and the Dart player.
///
/// Dart pushes what is playing (`update`, with the cover's bytes only when
/// the cover changed: an absent `artwork` keeps the current picture, a null
/// one clears it); the widget's buttons call back
/// into Dart (`action`, handled by `HomeWidgetBridge` on the Dart side).
/// Attached by MainActivity on the engine that audio_service keeps alive
/// with the playback, so it survives the UI being closed while music plays.
///
/// [channel] is null in a process that has not attached Dart yet — after
/// Android killed Musync, typically — and again once the engine it was
/// attached to is destroyed while the process lives on (audio_service
/// disposing its cached engine, say). The widget then offers to open the app
/// rather than buttons with no player behind them.
object WidgetBridge {
    const val CHANNEL = "com.atamsphrow.musync/widget"

    @Volatile
    var channel: MethodChannel? = null
        private set

    /// The engine [channel] talks to. Held only while it lives: cleared in
    /// [lifecycle] when it is destroyed, so no dead engine is retained.
    @Volatile
    private var engine: FlutterEngine? = null

    @Volatile
    private var appContext: Context? = null

    /// Whether a widget tap has a running Dart player to reach. Not just
    /// « a channel was attached once »: a destroyed engine (or one whose
    /// Dart isolate is gone) leaves a messenger that swallows every call.
    val isLive: Boolean
        get() {
            if (channel == null) return false
            val current = engine ?: return false
            return try {
                current.dartExecutor.isExecutingDart
            } catch (error: Exception) {
                false
            }
        }

    /// Registered once per engine: configureFlutterEngine runs again on
    /// every new activity over audio_service's cached engine.
    private val lifecycle = object : FlutterEngine.EngineLifecycleListener {
        override fun onPreEngineRestart() {
            // Hot restart: same engine, same messenger — Dart re-installs
            // its handler, nothing to drop.
        }

        override fun onEngineWillDestroy() {
            // Not removed from the engine here: destroy() is iterating its
            // listener set, and removing would throw. The engine drops the
            // set with itself.
            engine = null
            channel = null
            // Back to the « open the app » face: its taps start a fresh
            // player instead of calling into a dead one.
            appContext?.let { MusyncWidgetProvider.refreshAll(it) }
        }
    }

    fun attach(flutterEngine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        this.appContext = appContext
        if (engine !== flutterEngine) {
            engine?.removeEngineLifecycleListener(lifecycle)
            flutterEngine.addEngineLifecycleListener(lifecycle)
            engine = flutterEngine
        }
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        )
        this.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    if (call.hasArgument("artwork")) {
                        MusyncWidgetProvider.setArtwork(
                            call.argument<ByteArray>("artwork"),
                        )
                    }
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
