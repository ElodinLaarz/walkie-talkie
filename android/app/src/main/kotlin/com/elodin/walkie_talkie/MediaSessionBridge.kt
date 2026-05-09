package com.elodin.walkie_talkie

import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Bridges the Android MediaSessionManager to Flutter by subscribing to the active
 * MediaController for a supported music/podcast app and dispatching track metadata
 * via [onMetadata]. Supported apps: YouTube Music, Pocket Casts.
 *
 * Requires the user to have granted notification listener access for this app
 * (Settings → Apps → Special app access → Notification access). If access has
 * not been granted yet, [attach] logs a warning and returns without crashing;
 * the host falls back to placeholder track data.
 *
 * Call [attach] on Activity start/resume — it is safe to call repeatedly.
 * The sessions-changed listener is registered only once; the scan+dispatch runs
 * on every call so that a permission grant or session change that occurred while
 * backgrounded is picked up immediately on resume. Call [detach] on destroy.
 *
 * Call [replayLastMetadata] when the Flutter EventChannel listener first attaches
 * so any metadata that was dispatched before Flutter started listening is replayed.
 */
class MediaSessionBridge(
    private val context: Context,
    private val onMetadata: (Map<String, Any?>) -> Unit,
) {
    companion object {
        private const val TAG = "MediaSessionBridge"
        private const val YT_MUSIC_PKG = "com.google.android.apps.youtube.music"
        private const val POCKET_CASTS_PKG = "au.com.shiftyjelly.pocketcasts"

        /** Maps package name → Flutter wire key (must match MediaSource.wireKey in Dart). */
        private val PKG_TO_WIRE_KEY = mapOf(
            YT_MUSIC_PKG to "YouTube Music",
            POCKET_CASTS_PKG to "pocket_casts",
        )
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var activeController: MediaController? = null
    private var isListenerRegistered = false

    /** Last dispatched event; replayed to late Flutter listeners via [replayLastMetadata]. */
    private var lastMetadata: Map<String, Any?>? = null

    private val sessionManager: MediaSessionManager by lazy {
        context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
    }

    private val controllerCallback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) {
            dispatchMetadata(activeController, metadata)
        }

        override fun onPlaybackStateChanged(state: PlaybackState?) {
            dispatchMetadata(activeController, activeController?.metadata)
        }

        override fun onSessionDestroyed() {
            val pkg = activeController?.packageName ?: "unknown"
            Log.i(TAG, "$pkg session destroyed")
            activeController?.unregisterCallback(this)
            activeController = null
            emit(mapOf("type" to "mediaMetadata", "available" to false))
            if (isListenerRegistered) scanForBestSession()
        }
    }

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        Log.d(TAG, "Active sessions changed: ${controllers?.size ?: 0}")
        val best = bestController(controllers)
        when {
            best != null && best.sessionToken != activeController?.sessionToken -> {
                switchTo(best)
            }
            best == null && activeController != null -> {
                Log.i(TAG, "${activeController?.packageName} session no longer active")
                activeController?.unregisterCallback(controllerCallback)
                activeController = null
                emit(mapOf("type" to "mediaMetadata", "available" to false))
            }
        }
    }

    /**
     * Scan for active sessions from supported apps and dispatch metadata if found.
     * Registers the sessions-changed listener only on the first successful call
     * (guarded by [isListenerRegistered]).
     *
     * Safe to call from Activity.onResume() — re-registers nothing, but always
     * re-scans so a session that appeared while backgrounded is picked up, and a
     * SecurityException after a permission revoke cleans up state.
     */
    fun attach() {
        val notifComponent = ComponentName(context, WalkieTalkieNotificationListener::class.java)
        try {
            val controllers = sessionManager.getActiveSessions(notifComponent)

            // Register the listener only once — repeated calls must not stack listeners.
            if (!isListenerRegistered) {
                sessionManager.addOnActiveSessionsChangedListener(
                    sessionsListener, notifComponent, mainHandler
                )
                isListenerRegistered = true
            }

            // Always re-scan: a session may have started while backgrounded, or an existing
            // session may have changed identity (new MediaSession token).
            val best = bestController(controllers)
            when {
                best != null && best.sessionToken != activeController?.sessionToken -> {
                    switchTo(best)
                }
                best == null && activeController != null -> {
                    activeController?.unregisterCallback(controllerCallback)
                    activeController = null
                    emit(mapOf("type" to "mediaMetadata", "available" to false))
                }
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "Notification listener not enabled: ${e.message}")
            // Permission revoked while attached — tear down the registered listener and controller.
            if (isListenerRegistered) {
                isListenerRegistered = false
                try { sessionManager.removeOnActiveSessionsChangedListener(sessionsListener) } catch (_: Exception) {}
                activeController?.unregisterCallback(controllerCallback)
                activeController = null
                emit(mapOf("type" to "mediaMetadata", "available" to false))
            }
        }
    }

    /**
     * Unsubscribe from MediaSessionManager and release the active controller.
     * Call from Activity.onDestroy().
     */
    fun detach() {
        isListenerRegistered = false
        try {
            sessionManager.removeOnActiveSessionsChangedListener(sessionsListener)
        } catch (_: Exception) {}
        activeController?.unregisterCallback(controllerCallback)
        activeController = null
        lastMetadata = null
    }

    /**
     * Re-dispatch the last known metadata event to a newly-attached Flutter listener.
     * Call this from EventChannel.StreamHandler.onListen() so that metadata dispatched
     * before Flutter started listening is not permanently lost.
     */
    fun replayLastMetadata() {
        lastMetadata?.let { onMetadata(it) }
    }

    /**
     * Pick the best controller from [controllers]: prefers a supported app that is
     * actively playing; falls back to the first supported app in the list.
     */
    private fun bestController(controllers: List<MediaController>?): MediaController? {
        val supported = controllers?.filter { PKG_TO_WIRE_KEY.containsKey(it.packageName) }
            ?: return null
        return supported.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: supported.firstOrNull()
    }

    private fun scanForBestSession() {
        val notifComponent = ComponentName(context, WalkieTalkieNotificationListener::class.java)
        try {
            val controllers = sessionManager.getActiveSessions(notifComponent)
            val best = bestController(controllers)
            if (best != null) switchTo(best)
        } catch (_: SecurityException) {}
    }

    private fun switchTo(controller: MediaController) {
        activeController?.unregisterCallback(controllerCallback)
        activeController = controller
        controller.registerCallback(controllerCallback, mainHandler)
        Log.i(TAG, "Subscribed to ${controller.packageName} MediaSession")
        dispatchMetadata(controller, controller.metadata)
    }

    private fun dispatchMetadata(controller: MediaController?, metadata: MediaMetadata?) {
        if (controller == null) return
        val state = controller.playbackState
        val playing = state?.state == PlaybackState.STATE_PLAYING
        val positionMs = state?.position ?: 0L
        val title = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        val artist = metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
            ?: ""
        val durationMs = metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION)
            ?.takeIf { it > 0 } ?: 0L
        val sourceWireKey = PKG_TO_WIRE_KEY[controller.packageName] ?: return

        emit(
            mapOf(
                "type" to "mediaMetadata",
                "available" to true,
                "sourceWireKey" to sourceWireKey,
                "title" to title,
                "artist" to artist,
                "durationMs" to durationMs,
                "positionMs" to positionMs,
                "playing" to playing,
            )
        )
    }

    private fun emit(event: Map<String, Any?>) {
        lastMetadata = event
        onMetadata(event)
    }
}
