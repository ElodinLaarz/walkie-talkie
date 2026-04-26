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

    // Audio engine and mixer owned by MainActivity; lifecycle follows
    // startVoice/stopVoice calls so they only run while the user is in a room.
    private var audioEngineManager: AudioEngineManager? = null
    private var audioMixerManager: AudioMixerManager? = null
    private var voiceActive = false
    private var currentlyMuted = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize Bluetooth manager
        bluetoothManager = BluetoothLeAudioManager(this).apply {
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
                "startVoice" -> {
                    Log.i(TAG, "Starting voice capture")
                    // AudioMixerManager initializes the native g_audioMixer global
                    // that the Oboe callback reads — must be created first.
                    if (audioMixerManager == null) {
                        audioMixerManager = AudioMixerManager()
                    }
                    if (audioEngineManager == null) {
                        audioEngineManager = AudioEngineManager()
                    }
                    val success = audioEngineManager?.start() ?: false
                    voiceActive = success
                    if (success) {
                        // Apply the pre-existing mute state to the fresh engine.
                        audioEngineManager?.setMuted(currentlyMuted)
                        emitTalkingPeers()
                    }
                    result.success(success)
                }
                "stopVoice" -> {
                    Log.i(TAG, "Stopping voice capture")
                    audioEngineManager?.stop()
                    audioEngineManager = null
                    audioMixerManager?.clear()
                    audioMixerManager = null
                    voiceActive = false
                    sendEventToFlutter(mapOf("type" to "talkingPeers", "peers" to emptyList<String>()))
                    result.success(true)
                }
                "setMuted" -> {
                    val muted = call.argument<Boolean>("muted") ?: true
                    Log.i(TAG, "Setting mute: $muted")
                    currentlyMuted = muted
                    audioEngineManager?.setMuted(muted)
                    emitTalkingPeers()
                    result.success(true)
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

    /**
     * Emit a talkingPeers event reflecting the current local voice state.
     * The sentinel peer ID 'local' represents this device's mic. Remote peers
     * will be added once BLE audio transport lands.
     */
    private fun emitTalkingPeers() {
        val peers: List<String> = if (voiceActive && !currentlyMuted) listOf("local") else emptyList()
        sendEventToFlutter(mapOf("type" to "talkingPeers", "peers" to peers))
    }

    private fun sendEventToFlutter(event: Map<String, Any>) {
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(event)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        audioEngineManager?.stop()
        audioEngineManager = null
        audioMixerManager?.clear()
        audioMixerManager = null
        bluetoothManager?.cleanup()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
    }
}
