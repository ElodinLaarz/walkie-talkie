package com.elodin.walkie_talkie

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service that keeps the walkie-talkie session alive when the
 * screen is off. Manages the persistent notification and will own BLE
 * connectivity once that lands.
 *
 * Audio engine lifecycle is handled separately via the startVoice / stopVoice
 * MethodChannel calls so the engine only runs while the user is in a room.
 *
 * The service also owns the Audio Focus request (#55): when a phone call
 * comes in or another media app starts playing, the listener routes the
 * focus-change events into [AudioEngineManager] so streams pause / duck
 * instead of fighting the system for the audio path.
 */
class WalkieTalkieService : Service() {
    companion object {
        private const val TAG = "WalkieTalkieService"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "walkie_talkie_channel"
        const val EXTRA_FREQ = "freq"
        const val EXTRA_ACTION = "action"
        const val ACTION_LEAVE = "leaveRoom"
    }

    private var currentFreq: String? = null
    private var audioFocusManager: AudioFocusManager? = null
    private val audioEngineManager: AudioEngineManager by lazy { AudioEngineManager() }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "Service created")
        createNotificationChannel()
        startForegroundWithNotification(freq = null)
        requestAudioFocus()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val freq = intent?.getStringExtra(EXTRA_FREQ)
        if (freq != currentFreq) {
            currentFreq = freq
            updateNotification(freq)
        }
        Log.i(TAG, "Service started, freq=$freq")
        return START_REDELIVER_INTENT
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.i(TAG, "Service destroyed")
        audioEngineManager.stop()
        audioFocusManager?.abandon()
        audioFocusManager = null
    }

    /**
     * Request audio focus and route focus-change callbacks into the
     * native audio engine. Failure to acquire focus is non-fatal — the
     * walkie still works, it just won't pause / duck cleanly when the
     * system reclaims audio.
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
     * Pause / resume return values are non-fatal but worth surfacing in
     * logcat: an Oboe failure here means the system audio path is in an
     * unexpected state, and the next bug report should include it.
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
                audioEngineManager.setDuckingVolume(AudioFocusManager.DUCK_VOLUME)
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
            "Walkie Talkie Service",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps the walkie-talkie connection active"
        }
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(channel)
    }

    private fun buildNotification(freq: String?) = run {
        val contentText = if (freq != null) "On $freq · Tap to return" else "Connected and ready to communicate"

        val leavePendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(EXTRA_ACTION, ACTION_LEAVE)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
                setPackage(packageName)
            }
        val tapPendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Walkie Talkie Active")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(tapPendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Leave", leavePendingIntent)
            .build()
    }

    private fun startForegroundWithNotification(freq: String?) {
        val notification = buildNotification(freq)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
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
