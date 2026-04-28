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
        private const val CONTROL_BYTES_EVENT_CHANNEL = "com.elodin.walkie_talkie/control_bytes"

        init {
            System.loadLibrary("walkie_talkie_audio")
        }
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var controlBytesEventChannel: EventChannel? = null
    private var bluetoothManager: BluetoothLeAudioManager? = null
    private var audioRoutingManager: AudioRoutingManager? = null
    private var gattServerManager: GattServerManager? = null
    private var eventSink: EventChannel.EventSink? = null
    private var controlBytesSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register for native voice activity callbacks
        nativeRegisterForCallbacks()

        // Initialize audio routing manager
        // Auto-detect will be started when voice capture begins (startVoice)
        audioRoutingManager = AudioRoutingManager(this)

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
                    val freq = call.argument<String>("freq")
                    Log.i(TAG, "Starting WalkieTalkieService, freq=$freq")
                    val intent = Intent(this, WalkieTalkieService::class.java).apply {
                        if (freq != null) putExtra(WalkieTalkieService.EXTRA_FREQ, freq)
                    }
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
                "setAudioOutput" -> {
                    val output = call.argument<String>("output")
                    if (output != null && output in listOf("bluetooth", "earpiece", "speaker")) {
                        Log.i(TAG, "Setting audio output to: $output")
                        val success = audioRoutingManager?.setOutput(output) ?: false
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGUMENT", "output must be 'bluetooth', 'earpiece', or 'speaker'", null)
                    }
                }
                "startVoice" -> {
                    Log.i(TAG, "Starting voice capture")
                    // Start auto-detect for Bluetooth headset routing while voice is active
                    audioRoutingManager?.startAutoDetect { outputType ->
                        sendEventToFlutter(mapOf(
                            "type" to "audioOutputChanged",
                            "output" to outputType
                        ))
                    }
                    // Placeholder - native voice pipeline will be implemented later
                    result.success(true)
                }
                "stopVoice" -> {
                    Log.i(TAG, "Stopping voice capture")
                    // Stop auto-detect when voice stops
                    audioRoutingManager?.stopAutoDetect()
                    // Placeholder - native voice pipeline will be implemented later
                    result.success(true)
                }
                "setMuted" -> {
                    val muted = call.argument<Boolean>("muted")
                    if (muted != null) {
                        Log.i(TAG, "Setting mute state: $muted")
                        // Placeholder - will be implemented when native voice pipeline is ready
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGUMENT", "muted is required", null)
                    }
                }
                "startGattServer" -> {
                    Log.i(TAG, "Starting GATT server")
                    if (gattServerManager == null) {
                        gattServerManager = GattServerManager(this) { deviceAddress, bytes ->
                            sendControlBytesToFlutter(deviceAddress, bytes)
                        }
                    }
                    val success = gattServerManager?.start() ?: false
                    result.success(success)
                }
                "stopGattServer" -> {
                    Log.i(TAG, "Stopping GATT server")
                    gattServerManager?.stop()
                    gattServerManager = null
                    result.success(true)
                }
                "writeNotification" -> {
                    val deviceAddress = call.argument<String>("deviceAddress")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (deviceAddress != null && bytes != null) {
                        Log.d(TAG, "Writing ${bytes.size} bytes notification to $deviceAddress")
                        val success = gattServerManager?.notify(deviceAddress, bytes) ?: false
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGUMENT", "deviceAddress and bytes are required", null)
                    }
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

        // Set up EventChannel for control bytes (GATT REQUEST writes)
        controlBytesEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, CONTROL_BYTES_EVENT_CHANNEL)
        controlBytesEventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                Log.i(TAG, "Control bytes EventChannel listener attached")
                controlBytesSink = events
            }

            override fun onCancel(arguments: Any?) {
                Log.i(TAG, "Control bytes EventChannel listener cancelled")
                controlBytesSink = null
            }
        })
    }

    private fun sendEventToFlutter(event: Map<String, Any>) {
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(event)
        }
    }

    private fun sendControlBytesToFlutter(deviceAddress: String, bytes: ByteArray) {
        Handler(Looper.getMainLooper()).post {
            controlBytesSink?.success(mapOf(
                "endpointId" to deviceAddress,
                "bytes" to bytes
            ))
        }
    }

    // Called from JNI when voice activity crosses threshold
    fun sendLocalTalkingEvent(talking: Boolean) {
        sendEventToFlutter(mapOf(
            "type" to "localTalking",
            "talking" to talking
        ))
    }

    // Called when the notification's Leave action brings this activity back to
    // the foreground (singleTop launchMode prevents a new instance). The action
    // extra is forwarded to Flutter so the room screen can call leaveRoom().
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getStringExtra(WalkieTalkieService.EXTRA_ACTION) == WalkieTalkieService.ACTION_LEAVE) {
            Log.i(TAG, "Leave action received via notification intent")
            sendEventToFlutter(mapOf("type" to "leaveRoom"))
        }
    }
    override fun onDestroy() {
        super.onDestroy()
        nativeUnregisterCallbacks()
        audioRoutingManager?.cleanup()
        bluetoothManager?.cleanup()
        gattServerManager?.stop()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        controlBytesEventChannel?.setStreamHandler(null)
    }

    // Native methods for voice activity detection callbacks
    private external fun nativeRegisterForCallbacks()
    private external fun nativeUnregisterCallbacks()
}
