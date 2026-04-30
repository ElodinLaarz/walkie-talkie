package com.elodin.walkie_talkie

import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.util.Log
import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "MainActivity"
        private const val METHOD_CHANNEL = "com.elodin.walkie_talkie/audio"
        private const val EVENT_CHANNEL = "com.elodin.walkie_talkie/audio_events"
        private const val CONTROL_BYTES_EVENT_CHANNEL = "com.elodin.walkie_talkie/control_bytes"

        init {
            System.loadLibrary("walkie_talkie_audio")
        }

        /** Weak ref so the activity can be GC'd normally; the service's
         *  static dispatch hook never holds the activity past its natural
         *  lifecycle. */
        @Volatile
        private var instance: WeakReference<MainActivity>? = null

        /**
         * Called by [WalkieTalkieService] when a notification-button or
         * MediaSession callback fires. Forwards the action as an audio
         * EventChannel event so the Flutter room screen can apply it.
         * No-op when the activity isn't around: the FlutterEngine is gone
         * with it, so there's nothing to deliver to.
         */
        fun dispatchEventFromService(action: String) {
            val activity = instance?.get() ?: return
            val type = when (action) {
                WalkieTalkieService.ACTION_LEAVE -> "leaveRoom"
                WalkieTalkieService.ACTION_PTT_TOGGLE -> "pttToggle"
                WalkieTalkieService.ACTION_MUTE_TOGGLE -> "muteToggle"
                else -> return
            }
            activity.sendEventToFlutter(mapOf("type" to type))
        }
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var controlBytesEventChannel: EventChannel? = null
    private var bluetoothManager: BluetoothLeAudioManager? = null
    private var audioRoutingManager: AudioRoutingManager? = null
    private var gattServerManager: GattServerManager? = null
    private var gattClientManager: GattClientManager? = null
    private var hostAdvertiser: HostAdvertiser? = null
    private var voiceTransport: L2capVoiceTransport? = null
    private var eventSink: EventChannel.EventSink? = null
    private var controlBytesSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Publish a weak reference for the service's static dispatch hook
        // so notification-button / headset events can reach the EventChannel
        // without forcing an activity launch (issue #97).
        instance = WeakReference(this)

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
                        // Update the MediaStyle notification's Mute/Unmute
                        // label directly on the running service — no
                        // `startService` so we don't accidentally spin up an
                        // FGS just to refresh a label when no room is active.
                        WalkieTalkieService.getRunning()?.setMuteState(muted)
                        // Native engine `setMuted` will be implemented when the
                        // native voice pipeline lands; for now this is a no-op
                        // beyond the notification label sync above.
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGUMENT", "muted is required", null)
                    }
                }
                "startAdvertising" -> {
                    val sessionUuid = call.argument<String>("sessionUuid")
                    val displayName = call.argument<String>("displayName")
                    if (sessionUuid == null || displayName == null) {
                        result.error(
                            "INVALID_ARGUMENT",
                            "sessionUuid and displayName are required",
                            null
                        )
                    } else {
                        // Don't echo sessionUuid / displayName here — both
                        // are user/session identifiers and logcat is broadly
                        // readable on dev builds.
                        Log.i(TAG, "Starting LE advertising")
                        if (hostAdvertiser == null) {
                            hostAdvertiser = HostAdvertiser(this)
                        }
                        val success = hostAdvertiser?.start(sessionUuid, displayName) ?: false
                        result.success(success)
                    }
                }
                "stopAdvertising" -> {
                    Log.i(TAG, "Stopping LE advertising")
                    // Propagate the underlying boolean so a SecurityException
                    // inside HostAdvertiser.stop() doesn't pretend to be a
                    // clean shutdown on the Dart side.
                    val success = hostAdvertiser?.stop() ?: true
                    result.success(success)
                }
                "startGattServer" -> {
                    Log.i(TAG, "Starting GATT server")
                    if (gattServerManager == null) {
                        gattServerManager = GattServerManager(
                            context = this,
                            onBytesReceived = { deviceAddress, bytes ->
                                sendControlBytesToFlutter(deviceAddress, bytes)
                            },
                            onError = { reason ->
                                sendEventToFlutter(mapOf(
                                    "type" to "gattError",
                                    "reason" to reason
                                ))
                            }
                        )
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
                "getCurrentRssi" -> {
                    // Returns one (peerId, rssi) entry per peer connected
                    // over the GATT link. Full implementation requires
                    // BluetoothGatt.readRemoteRssi on the client side
                    // (gattClientManager); the server side cannot read
                    // remote RSSI on its accepted connections. Until that
                    // sampling is wired we return an empty list rather
                    // than fabricating values; the Dart side already
                    // short-circuits a send when the list is empty.
                    result.success(emptyList<Map<String, Any>>())
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
                "connectToHost" -> {
                    val macAddress = call.argument<String>("macAddress")
                    if (macAddress == null) {
                        result.error("INVALID_ARGUMENT", "macAddress is required", null)
                    } else {
                        Log.i(TAG, "Connecting to host GATT server at $macAddress")
                        if (gattClientManager == null) {
                            gattClientManager = GattClientManager(
                                context = this,
                                onResponseBytes = { bytes ->
                                    // Forward RESPONSE bytes to Flutter via controlBytes stream
                                    // Use the MAC address as the endpointId (host identifier)
                                    sendControlBytesToFlutter(macAddress, bytes)
                                },
                                onError = { reason ->
                                    sendEventToFlutter(mapOf(
                                        "type" to "gattError",
                                        "reason" to reason
                                    ))
                                }
                            )
                        }
                        val success = gattClientManager?.connectToHost(macAddress) ?: false
                        result.success(success)
                    }
                }
                "disconnectFromHost" -> {
                    Log.i(TAG, "Disconnecting from host GATT server")
                    gattClientManager?.disconnect()
                    gattClientManager = null
                    result.success(true)
                }
                "writeRequest" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("INVALID_ARGUMENT", "bytes is required", null)
                    } else {
                        Log.d(TAG, "Writing ${bytes.size} bytes to REQUEST characteristic")
                        val success = gattClientManager?.writeRequest(bytes) ?: false
                        result.success(success)
                    }
                }
                "getNegotiatedMtu" -> {
                    // Returns the MTU that the GATT layer negotiated with
                    // [endpointId] (BT MAC), or null if no MTU has been
                    // observed yet. Per BLE spec the wire floor is 23 bytes
                    // (the value Android uses before any negotiation), so a
                    // null return signals "use the default — no negotiation
                    // has fired yet" rather than "the link is dead".
                    //
                    // Prefers the GATT *client* cache (guest side, where this
                    // device drove the MTU request via `requestMtu`) and falls
                    // back to the *server* cache (host side, where the peer
                    // negotiated the MTU). Either side can answer once
                    // `onMtuChanged` has fired for that link.
                    val endpointId = call.argument<String>("endpointId")
                    if (endpointId == null) {
                        result.error("INVALID_ARGUMENT", "endpointId is required", null)
                    } else {
                        val mtu = gattClientManager?.getMtu(endpointId)
                            ?: gattServerManager?.getMtu(endpointId)
                        result.success(mtu)
                    }
                }
                "startVoiceServer" -> {
                    Log.i(TAG, "Starting L2CAP voice server")
                    val bt = (getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
                    if (bt == null) {
                        result.error("BT_UNAVAILABLE", "BluetoothAdapter is null", null)
                    } else {
                        if (voiceTransport == null) {
                            voiceTransport = L2capVoiceTransport(
                                bluetoothAdapter = bt,
                                onVoiceFrame = { /* mix-minus wired in issue #48 */ },
                                onClientConnected = { addr ->
                                    sendEventToFlutter(mapOf(
                                        "type" to "voiceClientConnected",
                                        "address" to addr,
                                    ))
                                },
                                onError = { msg ->
                                    sendEventToFlutter(mapOf("type" to "error", "message" to msg))
                                },
                            )
                        }
                        val psm = voiceTransport?.startServer()
                        if (psm != null) result.success(psm)
                        else result.error("L2CAP_FAILED", "Failed to open L2CAP server socket", null)
                    }
                }
                "connectVoiceClient" -> {
                    val mac = call.argument<String>("macAddress")
                    val psm = call.argument<Int>("psm")
                    if (mac == null || psm == null) {
                        result.error("INVALID_ARGUMENT", "macAddress and psm are required", null)
                    } else {
                        Log.i(TAG, "Connecting L2CAP voice client to $mac PSM 0x${psm.toString(16)}")
                        val bt = (getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
                        if (bt == null) {
                            result.error("BT_UNAVAILABLE", "BluetoothAdapter is null", null)
                        } else {
                            if (voiceTransport == null) {
                                voiceTransport = L2capVoiceTransport(
                                    bluetoothAdapter = bt,
                                    onVoiceFrame = { /* playback wired in issue #48 */ },
                                    onClientConnected = {},
                                    onError = { msg ->
                                        sendEventToFlutter(mapOf("type" to "error", "message" to msg))
                                    },
                                )
                            }
                            // Connect blocks (with retries) — run off the main thread.
                            val transport = voiceTransport!!
                            Thread({
                                try {
                                    val ok = transport.connectClient(mac, psm)
                                    Handler(Looper.getMainLooper()).post { result.success(ok) }
                                } catch (e: Exception) {
                                    Log.e(TAG, "connectVoiceClient thread error: ${e.message}")
                                    Handler(Looper.getMainLooper()).post {
                                        result.error("L2CAP_ERROR", e.message, null)
                                    }
                                }
                            }, "L2capConnect").apply { isDaemon = true; start() }
                        }
                    }
                }
                "stopVoiceTransport" -> {
                    Log.i(TAG, "Stopping L2CAP voice transport")
                    voiceTransport?.stop()
                    voiceTransport = null
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

    // Called from JNI when an Oboe audio error occurs (e.g., permission revoked)
    fun sendAudioError(reason: String) {
        Log.e(TAG, "Audio error from native: $reason")
        sendEventToFlutter(mapOf(
            "type" to "audioError",
            "reason" to reason
        ))
    }

    // Called when the notification's Leave action brings this activity back
    // to the foreground (singleTop launchMode prevents a new instance). PTT
    // and Mute go through [WalkieTalkieService] → [dispatchEventFromService]
    // instead so they don't unlock the phone — only Leave routes here.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getStringExtra(WalkieTalkieService.EXTRA_ACTION) == WalkieTalkieService.ACTION_LEAVE) {
            Log.i(TAG, "Leave action received via notification intent")
            sendEventToFlutter(mapOf("type" to "leaveRoom"))
        }
    }
    override fun onDestroy() {
        super.onDestroy()
        // Clear our static dispatch hook so the service stops trying to
        // post events to a torn-down FlutterEngine. Compare-and-clear so
        // a freshly recreated activity that already wrote a newer ref
        // isn't accidentally wiped.
        if (instance?.get() === this) {
            instance = null
        }
        nativeUnregisterCallbacks()
        audioRoutingManager?.cleanup()
        bluetoothManager?.cleanup()
        voiceTransport?.stop()
        gattServerManager?.stop()
        gattClientManager?.disconnect()
        hostAdvertiser?.stop()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        controlBytesEventChannel?.setStreamHandler(null)
    }

    // Native methods for voice activity detection callbacks
    private external fun nativeRegisterForCallbacks()
    private external fun nativeUnregisterCallbacks()
}
