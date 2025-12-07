package com.elodin.walkie_talkie

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.util.Log
import android.os.Handler
import android.os.Looper

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "MainActivity"
        private const val METHOD_CHANNEL = "com.elodin.walkie_talkie/audio"
        private const val EVENT_CHANNEL = "com.elodin.walkie_talkie/audio_events"
    }
    
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var bluetoothManager: BluetoothLeAudioManager? = null
    private var eventSink: EventChannel.EventSink? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Initialize Bluetooth manager
        bluetoothManager = BluetoothLeAudioManager(this).apply {
            // Set up callbacks
            onDeviceDiscovered = { address, name ->
                Log.i(TAG, "Device discovered: $name ($address)")
                sendEventToFlutter(mapOf(
                    "type" to "deviceDiscovered",
                    "address" to address,
                    "name" to name
                ))
            }
            
            onDeviceConnected = { address ->
                Log.i(TAG, "Device connected: $address")
                sendEventToFlutter(mapOf(
                    "type" to "deviceConnected",
                    "address" to address
                ))
            }
            
            onDeviceDisconnected = { address ->
                Log.i(TAG, "Device disconnected: $address")
                sendEventToFlutter(mapOf(
                    "type" to "deviceDisconnected",
                    "address" to address
                ))
            }
            
            onError = { message ->
                Log.e(TAG, "Bluetooth error: $message")
                sendEventToFlutter(mapOf(
                    "type" to "error",
                    "message" to message
                ))
            }
        }
        
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
                    Log.i(TAG, "Starting Bluetooth LE Audio scan")
                    val success = bluetoothManager?.startScan() ?: false
                    result.success(success)
                }
                "stopScan" -> {
                    Log.i(TAG, "Stopping Bluetooth scan")
                    bluetoothManager?.stopScan()
                    result.success(true)
                }
                "connectDevice" -> {
                    val macAddress = call.argument<String>("macAddress")
                    if (macAddress != null) {
                        Log.i(TAG, "Connecting to device: $macAddress")
                        val success = bluetoothManager?.connectDevice(macAddress) ?: false
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGUMENT", "macAddress is required", null)
                    }
                }
                "disconnectDevice" -> {
                    val macAddress = call.argument<String>("macAddress")
                    if (macAddress != null) {
                        Log.i(TAG, "Disconnecting from device: $macAddress")
                        val success = bluetoothManager?.disconnectDevice(macAddress) ?: false
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGUMENT", "macAddress is required", null)
                    }
                }
                "getConnectedDevices" -> {
                    val devices = bluetoothManager?.getConnectedDevices() ?: emptyList()
                    val deviceList = devices.map { (address, name) ->
                        mapOf("address" to address, "name" to name)
                    }
                    result.success(deviceList)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // Set up EventChannel for Native -> Flutter events
        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
        eventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                Log.i(TAG, "EventChannel listener attached")
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                Log.i(TAG, "EventChannel listener cancelled")
                eventSink = null
            }
        })
    }
    
    private fun sendEventToFlutter(event: Map<String, Any>) {
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(event)
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        bluetoothManager?.cleanup()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
    }
}
