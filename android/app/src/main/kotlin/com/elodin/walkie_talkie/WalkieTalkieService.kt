package com.elodin.walkie_talkie

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
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

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "Service created")
        createNotificationChannel()
        startForegroundWithNotification(freq = null)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val freq = intent?.getStringExtra(EXTRA_FREQ)
        if (freq != null && freq != currentFreq) {
            currentFreq = freq
            updateNotification(freq)
        }
        Log.i(TAG, "Service started, freq=$freq")
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.i(TAG, "Service destroyed")
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

        val tapPendingIntent = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
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
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(freq: String) {
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, buildNotification(freq))
    }
}
