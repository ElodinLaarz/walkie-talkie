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
 * YouTube Music MediaController and dispatching track metadata via [onMetadata].
 *
 * Requires the user to have granted notification listener access for this app
 * (Settings → Apps → Special app access → Notification access). If access has
 * not been granted yet, [attach] logs a warning and returns without crashing;
 * the host falls back to placeholder track data.
 *
 * Call [attach] on Activity start/resume (idempotent), [detach] on destroy.
 */
class MediaSessionBridge(
    private val context: Context,
    private val onMetadata: (Map<String, Any?>) -> Unit,
) {
    companion object {
        private const val TAG = "MediaSessionBridge"
        private const val YT_MUSIC_PKG = "com.google.android.apps.youtube.music"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var activeController: MediaController? = null
    private var isAttached = false

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
            Log.i(TAG, "YouTube Music session destroyed")
            activeController?.unregisterCallback(this)
            activeController = null
            onMetadata(mapOf("type" to "mediaMetadata", "available" to false))
            // Scan remaining active sessions in case another YT Music instance exists
            if (isAttached) scanForYtMusic()
        }
    }

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        Log.d(TAG, "Active sessions changed: ${controllers?.size ?: 0}")
        val ytMusic = controllers?.firstOrNull { it.packageName == YT_MUSIC_PKG }
        when {
            ytMusic != null && ytMusic.sessionToken != activeController?.sessionToken -> {
                switchTo(ytMusic)
            }
            ytMusic == null && activeController != null -> {
                Log.i(TAG, "YouTube Music session no longer active")
                activeController?.unregisterCallback(controllerCallback)
                activeController = null
                onMetadata(mapOf("type" to "mediaMetadata", "available" to false))
            }
        }
    }

    /**
     * Subscribe to MediaSessionManager. Safe to call multiple times — only attaches once.
     * Call on Activity resume so permission grants that happened while backgrounded are picked up.
     */
    fun attach() {
        if (isAttached) return
        val notifComponent = ComponentName(context, WalkieTalkieNotificationListener::class.java)
        try {
            val controllers = sessionManager.getActiveSessions(notifComponent)
            sessionManager.addOnActiveSessionsChangedListener(
                sessionsListener, notifComponent, mainHandler
            )
            isAttached = true
            val ytMusic = controllers.firstOrNull { it.packageName == YT_MUSIC_PKG }
            if (ytMusic != null) switchTo(ytMusic)
        } catch (e: SecurityException) {
            // User hasn't granted notification access yet — graceful degradation, placeholder shown.
            Log.w(TAG, "Notification listener not enabled: ${e.message}")
        }
    }

    /**
     * Unsubscribe from MediaSessionManager and release the active controller.
     * Call from Activity.onDestroy().
     */
    fun detach() {
        isAttached = false
        try {
            sessionManager.removeOnActiveSessionsChangedListener(sessionsListener)
        } catch (_: Exception) {}
        activeController?.unregisterCallback(controllerCallback)
        activeController = null
    }

    private fun scanForYtMusic() {
        val notifComponent = ComponentName(context, WalkieTalkieNotificationListener::class.java)
        try {
            val controllers = sessionManager.getActiveSessions(notifComponent)
            val ytMusic = controllers.firstOrNull { it.packageName == YT_MUSIC_PKG }
            if (ytMusic != null) switchTo(ytMusic)
        } catch (_: SecurityException) {}
    }

    private fun switchTo(controller: MediaController) {
        activeController?.unregisterCallback(controllerCallback)
        activeController = controller
        controller.registerCallback(controllerCallback, mainHandler)
        Log.i(TAG, "Subscribed to YouTube Music MediaSession")
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

        onMetadata(
            mapOf(
                "type" to "mediaMetadata",
                "available" to true,
                "title" to title,
                "artist" to artist,
                "durationMs" to durationMs,
                "positionMs" to positionMs,
                "playing" to playing,
            )
        )
    }
}
