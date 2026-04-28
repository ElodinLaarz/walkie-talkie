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
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var controlBytesEventChannel: EventChannel? = null
    private var bluetoothManager: BluetoothLeAudioManager? = null
    private var audioRoutingManager: AudioRoutingManager? = null
    private var audioEngineManager: AudioEngineManager? = null
    private var gattServerManager: GattServerManager? = null
    private var eventSink: EventChannel.EventSink? = null
    private var controlBytesSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioRoutingManager = AudioRoutingManager(this)

        bluetoothManager = BluetoothLeAudioManager(this).apply {
            onDeviceDiscovered = { address, name ->
                sendEventToFlutter(mapOf("type" to "deviceDiscovered", "address" to address, "name" to name))
            }
            onDeviceConnected = { address ->
                sendEventToFlutter(mapOf("type" to "deviceConnected", "address" to address))
            }
            onDeviceDisconnected = { address ->
                sendEventToFlutter(mapOf("type" to "deviceDisconnected", "address" to address))
            }
            onError = { message ->
                sendEventToFlutter(mapOf("type" to "error", "message" to message))
            }
        }

        audioEngineManager = AudioEngineManager()

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val freq = call.argument<String>("freq")
                    val intent = Intent(this, WalkieTalkieService::class.java).apply {
                        if (freq != null) putExtra(WalkieTalkieService.EXTRA_FREQ, freq)
                    }
                    startForegroundService(intent)
                    result.success(true)
                }
                "stopService" -> {
                    stopService(Intent(this, WalkieTalkieService::class.java))
                    result.success(true)
                }
                "scanDevices" -> result.success(bluetoothManager?.startScan() ?: false)
                "stopScan" -> { bluetoothManager?.stopScan(); result.success(true) }
                "connectDevice" -> {
                    val mac = call.argument<String>("macAddress")
                    if (mac != null) result.success(bluetoothManager?.connectDevice(mac) ?: false)
                    else result.error("INVALID_ARGUMENT", "macAddress is required", null)
                }
                "disconnectDevice" -> {
                    val mac = call.argument<String>("macAddress")
                    if (mac != null) result.success(bluetoothManager?.disconnectDevice(mac) ?: false)
                    else result.error("INVALID_ARGUMENT", "macAddress is required", null)
                }
                "getConnectedDevices" -> {
                    val devices = bluetoothManager?.getConnectedDevices() ?: emptyList()
                    result.success(devices.map { (a, n) -> mapOf("address" to a, "name" to n) })
                }
                "setAudioOutput" -> {
                    val output = call.argument<String>("output")
                    if (output != null && output in listOf("bluetooth", "earpiece", "speaker")) {
                        result.success(audioRoutingManager?.setOutput(output) ?: false)
                    } else {
                        result.error("INVALID_ARGUMENT", "output must be bluetooth, earpiece, or speaker", null)
                    }
                }
                "startVoice" -> {
                    Log.i(TAG, "Starting voice capture")
                    audioRoutingManager?.startAutoDetect { outputType ->
                        sendEventToFlutter(mapOf("type" to "audioOutputChanged", "output" to outputType))
                    }
                    val success = audioEngineManager?.start { talking ->
                        Log.d(TAG, "Local talking state: $talking")
                        sendEventToFlutter(mapOf("type" to "localTalking", "talking" to talking))
                    } ?: false
                    result.success(success)
                }
                "stopVoice" -> {
                    Log.i(TAG, "Stopping voice capture")
                    audioRoutingManager?.stopAutoDetect()
                    audioEngineManager?.stop()
                    result.success(true)
                }
                "setMuted" -> {
                    val muted = call.argument<Boolean>("muted")
                    if (muted != null) result.success(audioEngineManager?.setMuted(muted) ?: true)
                    else result.error("INVALID_ARGUMENT", "muted is required", null)
                }
                "startGattServer" -> {
                    if (gattServerManager == null) {
                        gattServerManager = GattServerManager(this) { addr, bytes ->
                            sendControlBytesToFlutter(addr, bytes)
                        }
                    }
                    result.success(gattServerManager?.start() ?: false)
                }
                "stopGattServer" -> {
                    gattServerManager?.stop()
                    gattServerManager = null
                    result.success(true)
                }
                "writeNotification" -> {
                    val deviceAddress = call.argument<String>("deviceAddress")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (deviceAddress != null && bytes != null)
                        result.success(gattServerManager?.notify(deviceAddress, bytes) ?: false)
                    else result.error("INVALID_ARGUMENT", "deviceAddress and bytes are required", null)
                }
                "writeControlBytes" -> {
                    // Guest->host GATT write. GattClientManager (issue #43) will handle the actual
                    // write; until then the call succeeds silently so the transport does not crash.
                    Log.d(TAG, "writeControlBytes (GATT client not yet wired)")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
        eventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
            override fun onCancel(arguments: Any?) { eventSink = null }
        })

        controlBytesEventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, CONTROL_BYTES_EVENT_CHANNEL)
        controlBytesEventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { controlBytesSink = events }
            override fun onCancel(arguments: Any?) { controlBytesSink = null }
        })
    }

    private fun sendEventToFlutter(event: Map<String, Any>) {
        Handler(Looper.getMainLooper()).post { eventSink?.success(event) }
    }

    private fun sendControlBytesToFlutter(deviceAddress: String, bytes: ByteArray) {
        Handler(Looper.getMainLooper()).post {
            controlBytesSink?.success(mapOf("endpointId" to deviceAddress, "bytes" to bytes))
        }
    }

    // Called when the notification Leave action brings this activity back to the foreground.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getStringExtra(WalkieTalkieService.EXTRA_ACTION) == WalkieTalkieService.ACTION_LEAVE) {
            Log.i(TAG, "Leave action received via notification intent")
            sendEventToFlutter(mapOf("type" to "leaveRoom"))
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        audioEngineManager?.stop()
        audioRoutingManager?.cleanup()
        bluetoothManager?.cleanup()
        gattServerManager?.stop()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        controlBytesEventChannel?.setStreamHandler(null)
    }
}