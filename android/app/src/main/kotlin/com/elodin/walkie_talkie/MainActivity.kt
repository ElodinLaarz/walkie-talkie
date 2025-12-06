package com.elodin.walkie_talkie

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.util.Log

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "MainActivity"
        private const val METHOD_CHANNEL = "com.elodin.walkie_talkie/audio"
        private const val EVENT_CHANNEL = "com.elodin.walkie_talkie/audio_events"
    }
    
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Set up MethodChannel for Flutter -> Native communication
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    Log.i(TAG, "Starting WalkieTalkieService")
                    val intent = Intent(this, WalkieTalkieService::class.java)
                    startForegroundService(intent)
                    result.success(true)
                }
                "stopService" -> {
                    Log.i(TAG, "Stopping WalkieTalkieService")
                    val intent = Intent(this, WalkieTalkieService::class.java)
                    stopService(intent)
                    result.success(true)
                }
                "scanDevices" -> {
                    Log.i(TAG, "Scanning for Bluetooth LE Audio devices")
                    // TODO: Implement Bluetooth LE Audio scanning
                    result.success(emptyList<String>())
                }
                "connectDevice" -> {
                    val macAddress = call.argument<String>("macAddress")
                    Log.i(TAG, "Connecting to device: $macAddress")
                    // TODO: Implement Bluetooth LE Audio connection
                    result.success(true)
                }
                "disconnectDevice" -> {
                    val macAddress = call.argument<String>("macAddress")
                    Log.i(TAG, "Disconnecting from device: $macAddress")
                    // TODO: Implement Bluetooth LE Audio disconnection
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // Set up EventChannel for Native -> Flutter events
        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
        // TODO: Implement event stream for audio levels, connection status, etc.
    }
    
    override fun onDestroy() {
        super.onDestroy()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
    }
}
