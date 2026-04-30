package com.elodin.walkie_talkie

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.media.app.NotificationCompat.MediaStyle

/**
 * Foreground service that keeps the walkie-talkie session alive when the
 * screen is off. Owns the persistent notification, the audio-focus request,
 * and the [MediaSessionCompat] that lets Android 11+ keep the mic stream
 * alive while the app is fully backgrounded.
 *
 * Audio engine lifecycle is handled separately via the startVoice / stopVoice
 * MethodChannel calls so the engine only runs while the user is in a room.
 *
 * Why a MediaSession (issue #97):
 *   `android:foregroundServiceType="microphone"` is necessary but not
 *   sufficient on Android 11+. The OS can still suppress the mic stream
 *   when it judges the FGS isn't "actively engaging" the user. Holding a
 *   `MediaSessionCompat` in `STATE_PLAYING` whenever the user is in a
 *   room is the standard mitigation: it tells the audio policy we're a
 *   real, user-facing voice session. The session also gives us lock-screen
 *   PTT/mute/leave controls and wired/Bluetooth headset PTT routing
 *   essentially for free — KEYCODE_MEDIA_PLAY/PAUSE arrives at the
 *   session's `onPlay`/`onPause` callbacks.
 *
 * Audio focus mapping (handled by the listener in [requestAudioFocus]):
 *   - AUDIOFOCUS_GAIN: clear ducking, resume streams.
 *   - AUDIOFOCUS_LOSS_TRANSIENT (e.g. incoming call): pause both streams.
 *   - AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK: keep streaming at full volume —
 *     voice communication is the duck-er, not the duck-ee. Other apps
 *     duck for us, not the other way around.
 *   - AUDIOFOCUS_LOSS (long-lived): pause; the user can return to the
 *     room. We deliberately don't auto-leave.
 */
class WalkieTalkieService : Service() {
    companion object {
        private const val TAG = "WalkieTalkieService"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "walkie_talkie_channel"
        private const val MEDIA_SESSION_TAG = "WalkieTalkieMediaSession"
        private const val ACTION_REQ_LEAVE = 1
        private const val ACTION_REQ_PTT = 2
        private const val ACTION_REQ_MUTE = 3
        private const val ACTION_REQ_TAP = 4

        const val EXTRA_FREQ = "freq"
        const val EXTRA_ACTION = "action"
        const val ACTION_LEAVE = "leaveRoom"
        const val ACTION_PTT_TOGGLE = "pttToggle"
        const val ACTION_MUTE_TOGGLE = "muteToggle"

        /** Live reference to the running service (or null while it isn't
         *  running). Used by [MainActivity] to dispatch UI-driven mute
         *  changes to [setMuteState] without spawning a new FGS just to
         *  refresh a notification label. */
        @Volatile
        private var instance: WalkieTalkieService? = null

        /** Returns the running service instance, or `null` if no FGS is up. */
        fun getRunning(): WalkieTalkieService? = instance
    }

    private var currentFreq: String? = null
    /** Mirrors the Dart-side mute state so the notification action label
     *  ("Mute" vs "Unmute") matches reality. Updated via `setMuteState` from
     *  [MainActivity]'s MethodChannel handler. */
    private var muted: Boolean = false
    private var audioFocusManager: AudioFocusManager? = null
    private var mediaSession: MediaSessionCompat? = null
    private val audioEngineManager: AudioEngineManager by lazy { AudioEngineManager() }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "Service created")
        instance = this
        createNotificationChannel()
        mediaSession = createMediaSession()
        // Start in PAUSED; promoted to PLAYING when a freq lands in
        // onStartCommand. Order matters — the notification we post in
        // startForegroundWithNotification embeds the session token, so the
        // session must exist first.
        updatePlaybackState(playing = false)
        startForegroundWithNotification(freq = null)
        requestAudioFocus()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Internal action triggered by the MediaStyle notification buttons
        // (PTT / Mute). We dispatch the event into Flutter without launching
        // the activity — pressing PTT on a lock-screen notification or a
        // headset shouldn't unlock the phone. The activity-launch path is
        // reserved for the "Leave" notification button (where opening the
        // app is the user's expected outcome) via a `getActivity` intent.
        val actionExtra = intent?.getStringExtra(EXTRA_ACTION)
        if (actionExtra != null) {
            handleNotificationAction(actionExtra)
            return START_NOT_STICKY
        }

        val freq = intent?.getStringExtra(EXTRA_FREQ)
        if (freq != currentFreq) {
            currentFreq = freq
            updatePlaybackState(playing = freq != null)
            updateNotification(freq)
        }
        Log.i(TAG, "Service started, freq=$freq")
        return START_REDELIVER_INTENT
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.i(TAG, "Service destroyed")
        instance = null
        audioEngineManager.stop()
        audioFocusManager?.abandon()
        audioFocusManager = null
        mediaSession?.run {
            setPlaybackState(
                PlaybackStateCompat.Builder()
                    .setState(PlaybackStateCompat.STATE_NONE, 0L, 1.0f)
                    .build()
            )
            isActive = false
            release()
        }
        mediaSession = null
    }

    /**
     * Relay a mute change from the Dart side so the notification button
     * label is in sync with the engine. Called from
     * [MainActivity]'s `setMuted` MethodChannel handler.
     */
    fun setMuteState(muted: Boolean) {
        if (this.muted == muted) return
        this.muted = muted
        updateNotification(currentFreq)
    }

    /**
     * Construct the [MediaSessionCompat]. The session is held for the
     * service's lifetime; only the `PlaybackState` toggles between
     * STATE_PLAYING (in a room) and STATE_PAUSED (idle).
     *
     * The callback dispatches lock-screen / headset button events to
     * Flutter via [dispatchEventToFlutter] — *not* via `startActivity`,
     * so a headset PTT press won't pull the user out of whatever they're
     * doing.
     */
    private fun createMediaSession(): MediaSessionCompat {
        return MediaSessionCompat(this, MEDIA_SESSION_TAG).apply {
            // Defaults on API 21+, but set explicitly so the contract is
            // visible at the call site. Without these the OS can't route
            // KEYCODE_MEDIA_* through to our callback.
            @Suppress("DEPRECATION")
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() {
                    Log.i(TAG, "MediaSession onPlay → PTT toggle")
                    dispatchEventToFlutter(ACTION_PTT_TOGGLE)
                }

                override fun onPause() {
                    Log.i(TAG, "MediaSession onPause → PTT toggle")
                    dispatchEventToFlutter(ACTION_PTT_TOGGLE)
                }

                override fun onStop() {
                    Log.i(TAG, "MediaSession onStop → leave")
                    dispatchEventToFlutter(ACTION_LEAVE)
                }
            })
            isActive = true
        }
    }

    /**
     * Push a new [PlaybackStateCompat] onto the active session. We always
     * advertise PLAY + PAUSE + STOP in the supported actions so headset
     * play/pause/stop buttons reach our callbacks regardless of which way
     * the toggle currently reads.
     *
     * STATE_PLAYING is what the Android 11+ audio policy looks for when
     * deciding whether an FGS is "actively engaging" enough to keep the
     * mic stream alive — keep it set whenever a frequency is active.
     */
    private fun updatePlaybackState(playing: Boolean) {
        val state = PlaybackStateCompat.Builder()
            .setActions(
                PlaybackStateCompat.ACTION_PLAY or
                    PlaybackStateCompat.ACTION_PAUSE or
                    PlaybackStateCompat.ACTION_PLAY_PAUSE or
                    PlaybackStateCompat.ACTION_STOP
            )
            .setState(
                if (playing) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN,
                1.0f,
                SystemClock.elapsedRealtime(),
            )
            .build()
        mediaSession?.setPlaybackState(state)
    }

    /**
     * Hand a service-side action off to Flutter without launching the
     * activity. Calls into [MainActivity.dispatchEventFromService] when
     * the activity is alive (i.e. the FlutterEngine is still wired up);
     * a no-op otherwise — if Flutter is gone, room state is gone too,
     * and the headset gesture has nothing meaningful to apply.
     *
     * Using a direct dispatch (vs. `startActivity`) is deliberate per
     * the Copilot review on this PR: a headset PTT press shouldn't pop
     * the app to the foreground.
     */
    private fun dispatchEventToFlutter(action: String) {
        MainActivity.dispatchEventFromService(action)
    }

    /**
     * Dispatcher for the notification-button intents that the service
     * receives via `getService` PendingIntents. PTT and Mute don't
     * require activity foregrounding — they just toggle voice state.
     * The Leave action skips this path entirely (its PendingIntent is
     * `getActivity`, so the system launches the activity directly).
     */
    private fun handleNotificationAction(action: String) {
        Log.i(TAG, "Notification action: $action")
        dispatchEventToFlutter(action)
    }

    /**
     * Request audio focus and route focus-change callbacks into the
     * native audio engine. Failure to acquire focus is non-fatal — the
     * walkie still works, it just won't pause cleanly when the system
     * reclaims audio.
     */
    private fun requestAudioFocus() {
        val mgr = AudioFocusManager(this)
        val granted = mgr.requestFocus { focusChange ->
            handleAudioFocusChange(focusChange)
        }
        audioFocusManager = mgr
        if (!granted) {
            Log.w(TAG, "Audio focus request denied; phone-call/Spotify clashes will not be handled")
        }
    }

    /**
     * Translate AudioManager focus-change codes to engine actions. Mapping
     * is documented in [AudioFocusManager]. Per #55 we deliberately don't
     * auto-leave the room on AUDIOFOCUS_LOSS — the user can return to a
     * paused room rather than losing their tune-in entirely.
     *
     * Per #97: AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK is a no-op now. We're a
     * voice-communication app, so other apps are expected to duck around
     * us; quieting our own output during e.g. a Maps nav prompt makes the
     * critical channel (the call) unintelligible.
     */
    private fun handleAudioFocusChange(focusChange: Int) {
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                audioEngineManager.setDuckingVolume(AudioFocusManager.FULL_VOLUME)
                if (!audioEngineManager.resumeStreams()) {
                    Log.w(TAG, "resumeStreams() reported failure on AUDIOFOCUS_GAIN")
                }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                if (!audioEngineManager.pauseStreams()) {
                    Log.w(TAG, "pauseStreams() reported failure on AUDIOFOCUS_LOSS_TRANSIENT")
                }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                Log.i(TAG, "Ignoring AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK — voice comms is the duck-er")
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                Log.w(TAG, "Long-lived audio focus loss — pausing; user must re-tune to recover")
                if (!audioEngineManager.pauseStreams()) {
                    Log.w(TAG, "pauseStreams() reported failure on AUDIOFOCUS_LOSS")
                }
            }
            else -> {
                Log.w(TAG, "Unhandled audio focus change: $focusChange")
            }
        }
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.fgs_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.fgs_channel_description)
        }
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(channel)
    }

    /** Build a `getService` PendingIntent that re-enters this service with
     *  an `EXTRA_ACTION` extra. Used for the notification's action buttons. */
    private fun servicePendingIntent(requestCode: Int, action: String): PendingIntent {
        val intent = Intent(this, WalkieTalkieService::class.java).apply {
            putExtra(EXTRA_ACTION, action)
        }
        return PendingIntent.getService(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildNotification(freq: String?) = run {
        val contentText = if (freq != null) {
            getString(R.string.fgs_notification_text_on_freq, freq)
        } else {
            getString(R.string.fgs_notification_text_idle)
        }

        // Tap the body of the notification to bring the activity back —
        // unchanged from the pre-#97 behaviour.
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
                setPackage(packageName)
            }
        val tapPendingIntent = PendingIntent.getActivity(
            this,
            ACTION_REQ_TAP,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // PTT + Mute go through the service (no activity launch). Leave
        // explicitly opens the activity — when the user taps Leave they
        // expect to land back in the app, on Discovery.
        val pttPi = servicePendingIntent(ACTION_REQ_PTT, ACTION_PTT_TOGGLE)
        val mutePi = servicePendingIntent(ACTION_REQ_MUTE, ACTION_MUTE_TOGGLE)
        val leaveActivityIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_ACTION, ACTION_LEAVE)
        }
        val leavePi = PendingIntent.getActivity(
            this,
            ACTION_REQ_LEAVE,
            leaveActivityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val muteLabel = if (muted) {
            getString(R.string.fgs_notification_action_unmute)
        } else {
            getString(R.string.fgs_notification_action_mute)
        }

        // The MediaStyle compact-view indices pick which actions appear
        // when the notification is collapsed (lock-screen or shade). We
        // surface PTT, Mute, and Leave — the three things a user might
        // need without unlocking.
        val mediaStyle = MediaStyle()
            .setShowActionsInCompactView(0, 1, 2)
        mediaSession?.sessionToken?.let { mediaStyle.setMediaSession(it) }

        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.fgs_notification_title))
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(tapPendingIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setStyle(mediaStyle)
            .addAction(
                android.R.drawable.ic_btn_speak_now,
                getString(R.string.fgs_notification_action_ptt),
                pttPi,
            )
            .addAction(
                if (muted) android.R.drawable.ic_lock_silent_mode_off
                else android.R.drawable.ic_lock_silent_mode,
                muteLabel,
                mutePi,
            )
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                getString(R.string.fgs_notification_action_leave),
                leavePi,
            )
            .build()
    }

    /**
     * Check if Bluetooth permissions are granted. On Android 12+ we need
     * BLUETOOTH_CONNECT to use FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE.
     */
    private fun hasBluetoothPermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            // On older APIs, BLUETOOTH permission is install-time, not runtime
            true
        }
    }

    private fun startForegroundWithNotification(freq: String?) {
        val notification = buildNotification(freq)
        val serviceType = if (hasBluetoothPermissions()) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        } else {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                serviceType,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                serviceType,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(freq: String?) {
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, buildNotification(freq))
    }
}
