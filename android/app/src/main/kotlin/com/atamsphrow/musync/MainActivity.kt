package com.atamsphrow.musync

import android.content.ContentUris
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.util.concurrent.atomic.AtomicBoolean

/// Must extend `AudioServiceActivity`, never `FlutterActivity`.
///
/// `audio_service` — pulled in by `just_audio_background` — runs the media
/// session in a FlutterEngine that it caches itself, so that playback survives
/// the UI being destroyed. `AudioServiceActivity` hands that same cached engine
/// to the Activity, which leaves exactly one engine, with an Activity attached
/// to it.
///
/// With a plain `FlutterActivity` there are two engines and the Activity's one
/// is not the one `audio_service` configured. That failed twice at launch, and
/// the app never got past its splash screen:
///
///  * `JustAudioBackground.init()` threw "The Activity class declared in your
///    AndroidManifest.xml is wrong or has not provided the correct
///    FlutterEngine", so `main()` aborted before the notification channel and
///    the background handler were installed;
///  * `permission_handler` found no Activity to attach its request to ("Unable
///    to detect current Activity"), so the startup permission prompt never
///    appeared — `READ_MEDIA_AUDIO` stayed denied and the library had nothing
///    to scan.
class MainActivity : AudioServiceActivity() {

    /// Paths handed over by a share or an "open with", waiting for Dart to
    /// collect them.
    ///
    /// Queued rather than pushed: the intent that started the app is available
    /// long before Dart is ready to receive anything, so the Dart side asks for
    /// them once it has a navigator to act with.
    private val pendingSharedAudio = mutableListOf<String>()

    /// Held so a later intent can reach Dart without waiting to be asked.
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        installCrashHandler()
        super.onCreate(savedInstanceState)
    }

    /// Records a crash on the Android side, which Dart structurally cannot see.
    ///
    /// The Dart handlers in `DebugLog.install` catch Flutter's errors and
    /// uncaught Dart exceptions. An uncaught exception on a Java thread is
    /// neither: the default handler kills the process, and the log — which is
    /// flushed to disk on a two-second debounce — loses whatever had not been
    /// written yet, along with any chance of recording the crash itself.
    ///
    /// So it is written here, synchronously, before the process goes away, and
    /// `NativeCrashReport.collect` picks it up on the next launch. `filesDir` is
    /// the app's own private storage, the same tree Dart's
    /// `getApplicationSupportDirectory` lives inside.
    ///
    /// The previous handler is always called afterwards. Swallowing it would
    /// leave a process that has already lost its state running as though nothing
    /// had happened, which is worse than the crash.
    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val text = StringWriter().also {
                    it.write("Thread : ${thread.name}\n")
                    error.printStackTrace(PrintWriter(it))
                }.toString()
                File(filesDir, NATIVE_CRASH_FILE).writeText(text)
            } catch (_: Throwable) {
                // Nothing useful left to do: the process is going down either
                // way, and a failure here must not replace the real crash.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        queueSharedAudio(intent)

        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_STORE_CHANNEL,
        )
        channel!!.setMethodCallHandler { call, result ->
                when (call.method) {
                    "rescan" -> rescan(call.argument<String>("path"), result)
                    "shareAudio" -> shareAudio(
                        (call.argument<Number>("mediaStoreId"))?.toLong(),
                        call.argument<String>("title"),
                        call.argument<String>("targetPackage"),
                        result,
                    )
                    "takeSharedAudio" -> {
                        // Draining is deliberate: a share is a one-shot event,
                        // and re-serving it would reopen the editor on every
                        // resume.
                        result.success(pendingSharedAudio.toList())
                        pendingSharedAudio.clear()
                    }
                    else -> result.notImplemented()
                }
        }
    }

    /// A share arriving while Musync is already running.
    ///
    /// `launchMode="singleTask"` routes it here instead of starting a second
    /// copy. Dart is then *told*, rather than left to work out when to ask:
    /// the first version relied on the app-lifecycle callback firing, which it
    /// does not reliably do when the activity was already in the foreground —
    /// so a share into a running Musync simply vanished.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        val before = pendingSharedAudio.size
        queueSharedAudio(intent)
        if (pendingSharedAudio.size > before) {
            runOnUiThread { channel?.invokeMethod("sharedAudioArrived", null) }
        }
    }

    /// Hands the track to another app through the system share sheet.
    ///
    /// Sends MediaStore's own content URI rather than a file path. A `file://`
    /// URI has been illegal to share since Android 7 — it raises
    /// FileUriExposedException — and the usual answer, a FileProvider, would
    /// mean declaring one and granting it the whole filesystem. None of that is
    /// needed here: the track is already indexed, so it already has a content
    /// URI that the receiving app can read with the audio permission it holds
    /// anyway.
    private fun shareAudio(
        mediaStoreId: Long?,
        title: String?,
        targetPackage: String?,
        result: MethodChannel.Result,
    ) {
        if (mediaStoreId == null || mediaStoreId <= 0) {
            result.error("no_id", "A MediaStore id is required.", null)
            return
        }

        val uri = ContentUris.withAppendedId(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            mediaStoreId,
        )

        // ACTION_VIEW when a package is named, ACTION_SEND otherwise.
        //
        // The two are not interchangeable, and that is why Musicolet never
        // appeared in the share sheet: SEND needs the receiving app to declare a
        // share receiver, which a music player has no reason to do. VIEW is what
        // a file manager uses for "open with", and it is the filter Musicolet
        // does declare. Naming the package skips the chooser entirely, which is
        // the point — the loop this app exists for is "write the lyrics, then
        // look at them in Musicolet", and a chooser in the middle of it is one
        // tap of pure friction.
        val intent = if (targetPackage.isNullOrEmpty()) {
            Intent(Intent.ACTION_SEND).apply {
                type = "audio/*"
                putExtra(Intent.EXTRA_STREAM, uri)
                if (!title.isNullOrEmpty()) putExtra(Intent.EXTRA_SUBJECT, title)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } else {
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "audio/*")
                setPackage(targetPackage)
                // Without this the receiving app gets a URI it is not allowed
                // to open, which reads to the user as "nothing happened".
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }

        try {
            startActivity(
                if (targetPackage.isNullOrEmpty()) {
                    Intent.createChooser(intent, title ?: "Partager")
                } else {
                    intent
                }
            )
            result.success(true)
        } catch (e: android.content.ActivityNotFoundException) {
            // Told apart from a general failure: "Musicolet is not installed"
            // is something the user can act on, "share failed" is not.
            result.error("not_installed", targetPackage, null)
        } catch (e: Exception) {
            result.error("share_failed", e.message, null)
        }
    }

    private fun queueSharedAudio(intent: Intent?) {
        if (intent == null) return

        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND ->
                listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
            Intent.ACTION_VIEW ->
                listOfNotNull(intent.data)
            else -> emptyList()
        }

        uris.mapNotNull(::resolveToFilePath).forEach {
            if (!pendingSharedAudio.contains(it)) pendingSharedAudio.add(it)
        }
    }

    /// Turns a shared URI into a path `dart:io` can open, or null.
    ///
    /// Musync edits tags in place, so a stream it cannot reach as a real file
    /// is of no use — copying it somewhere would produce a tagged duplicate the
    /// user never asked for. Returning null lets Dart say so plainly instead.
    private fun resolveToFilePath(uri: Uri): String? {
        if (uri.scheme == "file") {
            return uri.path?.takeIf { File(it).exists() }
        }
        if (uri.scheme != "content") return null

        // MediaColumns.DATA is deprecated because scoped storage usually makes
        // it useless. Musync holds MANAGE_EXTERNAL_STORAGE precisely so that it
        // stays usable — see PermissionService.requestWriteAccess.
        return try {
            contentResolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns.DATA),
                null,
                null,
                null,
            )?.use { cursor ->
                val column = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                if (column >= 0 && cursor.moveToFirst()) {
                    cursor.getString(column)?.takeIf { File(it).exists() }
                } else {
                    null
                }
            }
        } catch (_: SecurityException) {
            // A provider that won't grant us a look. Nothing to do but decline.
            null
        }
    }

    /// Re-indexes a file whose bytes Musync just rewrote.
    ///
    /// Embedding lyrics replaces the track through a temp file and a `rename`,
    /// which is atomic but hands the path a *new inode*. MediaStore keeps
    /// serving the old row until something tells it otherwise, so players that
    /// read the library through MediaStore — Musicolet among them — end up
    /// pointing at a file that no longer exists: the track goes silent, the
    /// player crash-loops, and the entry vanishes and returns once Android
    /// eventually rescans on its own. Players that walk the filesystem instead,
    /// like VLC, never notice. Hence this call, right after every write.
    private fun rescan(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("no_path", "A file path is required.", null)
            return
        }

        // The callback lands on a binder thread, whereas a MethodChannel result
        // has to be answered on the main thread — and exactly once. It also
        // isn't guaranteed to fire at all for a path the scanner can't read, so
        // the Dart side puts a timeout around this.
        val answered = AtomicBoolean(false)
        MediaScannerConnection.scanFile(applicationContext, arrayOf(path), null) { _, uri ->
            if (answered.compareAndSet(false, true)) {
                runOnUiThread { result.success(uri?.toString()) }
            }
        }
    }

    private companion object {
        const val MEDIA_STORE_CHANNEL = "com.atamsphrow.musync/media_store"

        /// Must match `NativeCrashReport.fileName` on the Dart side.
        const val NATIVE_CRASH_FILE = "native_crash.txt"
    }
}
