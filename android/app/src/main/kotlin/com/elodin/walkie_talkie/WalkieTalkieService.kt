package com.elodin.walkie_talkie

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service that manages Bluetooth LE Audio connections
 * and audio routing. Ensures the app continues running even when
 * the screen is off.
 */
class WalkieTalkieService : Service() {
    companion object {
        private const val TAG = "WalkieTalkieService"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "walkie_talkie_channel"
    }
    
    private lateinit var audioEngine: AudioEngineManager
    private lateinit var audioMixer: AudioMixerManager
    
    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "Service created")
        
        // Initialize audio components
        audioEngine = AudioEngineManager()
        audioMixer = AudioMixerManager()
        
        // Create notification channel
        createNotificationChannel()
        
        // Start foreground service
        startForegroundService()
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "Service started")
        
        // Start audio engine
        if (audioEngine.start()) {
            Log.i(TAG, "Audio engine started successfully")
        } else {
            Log.e(TAG, "Failed to start audio engine")
        }
        
        return START_STICKY
    }
    
    override fun onBind(intent: Intent?): IBinder? {
        // This service doesn't support binding
        return null
    }
    
    override fun onDestroy() {
        super.onDestroy()
        Log.i(TAG, "Service destroyed")
        
        // Clean up audio components
        audioEngine.stop()
        audioMixer.clear()
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
    
    private fun startForegroundService() {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Walkie Talkie Active")
            .setContentText("Connected and ready to communicate")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
    
    fun getAudioEngine(): AudioEngineManager = audioEngine
    fun getAudioMixer(): AudioMixerManager = audioMixer
}
