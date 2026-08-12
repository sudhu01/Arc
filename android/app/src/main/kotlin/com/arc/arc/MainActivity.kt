package com.arc.arc

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Arc's only platform glue.
 *
 * The rest timer lets the user pick their own alarm sound, and that sound has to
 * still play once Android has killed Arc — at which point the thing making noise
 * is the notification system, not this process. A notification channel can hold
 * a content:// URI, but the app that receives it (the system UI) has no
 * permission on a URI from Arc's private FileProvider unless Arc grants it.
 *
 * That grant is a one-line Android call with no Flutter plugin in front of it,
 * which is the whole reason this channel exists. `TimerSound.publish` calls it
 * every time the sound changes; the grant survives reboots because it is
 * re-issued on the next change and the URI itself is stable.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "grantSoundUri" -> {
                        val raw = call.argument<String>("uri")
                        if (raw.isNullOrEmpty()) {
                            result.error("no_uri", "grantSoundUri needs a uri", null)
                        } else {
                            result.success(grantSoundUri(Uri.parse(raw)))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Grants read on [uri] to every package that could be asked to play it.
     *
     * The system UI is the one that matters on stock Android; the others are
     * cheap insurance on OEM builds that route notification audio through their
     * own components. A package that isn't installed throws, and a sound that
     * one launcher can't read is not worth failing the whole setting over.
     */
    private fun grantSoundUri(uri: Uri): Boolean {
        var granted = false
        for (pkg in SOUND_CONSUMERS) {
            try {
                grantUriPermission(pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                granted = true
            } catch (_: Exception) {
                // Not installed on this device, or refused. Try the next one.
            }
        }
        return granted
    }

    companion object {
        private const val CHANNEL = "arc/timer_sound"

        private val SOUND_CONSUMERS = listOf(
            "com.android.systemui",
            "android",
            "com.android.settings",
        )
    }
}
