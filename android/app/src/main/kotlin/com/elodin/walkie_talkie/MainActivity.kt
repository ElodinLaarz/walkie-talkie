package com.elodin.walkie_talkie

import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.net.Uri
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
        private const val LOOPBACK_TEST_DEVICE_ID = -1

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
    private var mediaSessionBridge: MediaSessionBridge? = null
    private var audioRoutingManager: AudioRoutingManager? = null
    private var gattServerManager: GattServerManager? = null
    private var gattClientManager: GattClientManager? = null
    private var hostAdvertiser: HostAdvertiser? = null
    private var voiceTransport: L2capVoiceTransport? = null
    // @Volatile so background threads (L2CAP accept loop, mixer JNI callback)
    // see up-to-date values without data races on write-once / null-on-stop
    // transitions that happen on the main thread.
    @Volatile private var peerAudioManager: PeerAudioManager? = null
    @Volatile private var audioMixerManager: AudioMixerManager? = null
    private var isVoiceHost: Boolean = false
    // Incremented in stopVoice so any in-flight registerVoicePeer retries
    // from a prior session become no-ops in the new one.
    @Volatile private var voiceSessionId: Int = 0
    // Per-session first-frame sentinels. ConcurrentHashMap.newKeySet gives
    // a thread-safe Set (mutated from JNI mixer + L2CAP recv threads and
    // cleared on the main thread in stopVoice).
    private val firstEncodedFramePeers: MutableSet<String> =
        java.util.concurrent.ConcurrentHashMap.newKeySet()
    private val firstDecodedFramePeers: MutableSet<String> =
        java.util.concurrent.ConcurrentHashMap.newKeySet()
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
                    result.success(startVoiceCapture(loopbackTestMode = false))
                }
                "stopVoice" -> {
                    stopVoiceCapture()
                    result.success(true)
                }
                "startLoopbackTest" -> {
                    result.success(startVoiceCapture(loopbackTestMode = true))
                }
                "stopLoopbackTest" -> {
                    stopVoiceCapture()
                    result.success(true)
                }
                "setMuted" -> {
                    val muted = call.argument<Boolean>("muted")
                    if (muted != null) {
                        Log.i(TAG, "Setting mute state: $muted")
                        WalkieTalkieService.getRunning()?.setMuteState(muted)
                        WalkieTalkieService.getRunning()?.setEngineMuted(muted)
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
                            },
                            onServerReady = {
                                sendEventToFlutter(mapOf("type" to "gattServerReady"))
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
                    // Returns one {peerId, rssi} entry per active GATT link.
                    // Only the GATT client (guest) can read remote RSSI;
                    // the server side has no equivalent API.
                    val samples = gattClientManager?.getLatestRssiSamples() ?: emptyList()
                    result.success(samples)
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
                        val initiated = gattClientManager?.connectToHost(macAddress) { success ->
                            result.success(success)
                        } ?: false
                        if (!initiated) {
                            result.success(false)
                        }
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
                "writeControlBytes" -> {
                    // Guests write to the host's REQUEST characteristic via
                    // gattClientManager. Hosts fan-out via gattServerManager
                    // notifications to every connected guest device.
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("INVALID_ARGUMENT", "bytes is required", null)
                    } else {
                        val server = gattServerManager
                        if (server != null) {
                            // Host path: notify each connected guest.
                            val addresses = server.getConnectedAddresses()
                            Log.d(TAG, "Host broadcasting ${bytes.size} control bytes to ${addresses.size} guest(s)")
                            val success = addresses.fold(false) { any, addr ->
                                server.notify(addr, bytes) || any
                            }
                            result.success(success)
                        } else {
                            // Guest path: write to the host's REQUEST characteristic.
                            Log.d(TAG, "Writing ${bytes.size} control bytes")
                            val success = gattClientManager?.writeRequest(bytes) ?: false
                            result.success(success)
                        }
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
                        isVoiceHost = true
                        if (voiceTransport == null) {
                            voiceTransport = L2capVoiceTransport(
                                bluetoothAdapter = bt,
                                onVoiceFrame = { addr, frameBytes ->
                                    dispatchVoiceFrame(addr, frameBytes)
                                },
                                onClientConnected = { addr ->
                                    registerVoicePeer(addr)
                                    sendEventToFlutter(mapOf(
                                        "type" to "voiceClientConnected",
                                        "address" to addr,
                                    ))
                                    sendEventToFlutter(mapOf(
                                        "type" to "l2capOpen",
                                        "address" to addr,
                                        "role" to "host",
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
                                    onVoiceFrame = { addr, frameBytes ->
                                        dispatchVoiceFrame(addr, frameBytes)
                                    },
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
                                    Handler(Looper.getMainLooper()).post {
                                        if (ok) {
                                            // Register the host as our single peer so the mixer
                                            // thread can decode inbound frames and encode the mic
                                            // signal to send back.
                                            registerVoicePeer(mac)
                                            sendEventToFlutter(mapOf(
                                                "type" to "l2capOpen",
                                                "address" to mac,
                                                "role" to "guest",
                                            ))
                                        }
                                        result.success(ok)
                                    }
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
                "getLinkTelemetry" -> {
                    val mac = call.argument<String>("macAddress")
                    if (mac == null) {
                        result.error("INVALID_ARGUMENT", "macAddress is required", null)
                    } else {
                        val t = peerAudioManager?.getTelemetry(mac)
                        if (t == null) {
                            result.success(null)
                        } else {
                            result.success(intArrayOf(
                                t.underrunCount,
                                t.lateFrameCount,
                                t.targetDepthFrames,
                                t.currentDepthFrames,
                                t.currentBitrateBps,
                            ))
                        }
                    }
                }
                "setPeerBitrate" -> {
                    val mac = call.argument<String>("macAddress")
                    val bps = call.argument<Int>("bps")
                    if (mac == null || bps == null) {
                        result.error("INVALID_ARGUMENT", "macAddress and bps are required", null)
                    } else {
                        val applied = peerAudioManager?.setPeerBitrate(mac, bps) ?: -1
                        result.success(applied)
                    }
                }
                "getInitialLink" -> {
                    // Called by Flutter once the engine is ready to receive the
                    // launch-intent deep link (cold-start path). Returns the
                    // freq query param from a walkietalkie://join?freq=<name>
                    // URI, or null when the app was not opened via an invite link.
                    result.success(extractInviteFreq(intent))
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
                // Replay the last known media metadata in case it was dispatched
                // before Flutter attached its listener (bridge attaches at engine start
                // but Flutter's EventChannel listen() call comes later).
                mediaSessionBridge?.replayLastMetadata()
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

        // Wire the MediaSession bridge so the host sees real YouTube Music metadata
        // when notification listener access is granted.
        mediaSessionBridge = MediaSessionBridge(applicationContext) { metadata ->
            @Suppress("UNCHECKED_CAST")
            sendEventToFlutter(metadata as Map<String, Any>)
        }
        mediaSessionBridge?.attach()
    }

    private fun startVoiceCapture(loopbackTestMode: Boolean): Boolean {
        if (peerAudioManager != null) return true
        Log.i(TAG, if (loopbackTestMode) "Starting loopback voice test" else "Starting voice capture")
        val service = WalkieTalkieService.getRunning()
        if (service == null) {
            Log.e(TAG, "Cannot start voice: WalkieTalkieService is not running")
            return false
        }
        service.setLoopbackTestMode(loopbackTestMode)
        audioRoutingManager?.startAutoDetect { outputType ->
            sendEventToFlutter(mapOf(
                "type" to "audioOutputChanged",
                "output" to outputType
            ))
        }
        // Init the mixer (device 0 = local mic) and start the Oboe engine.
        audioMixerManager = AudioMixerManager()
        audioMixerManager?.addDevice(0)
        if (loopbackTestMode) {
            audioMixerManager?.addDevice(LOOPBACK_TEST_DEVICE_ID)
        }
        val engineStarted = service.startAudioEngine()
        if (!engineStarted) {
            Log.e(TAG, "Audio engine failed to start — rolling back partial init")
            service.setLoopbackTestMode(false)
            audioRoutingManager?.stopAutoDetect()
            audioMixerManager?.clear()
            audioMixerManager = null
            return false
        }
        // Init the per-peer manager and wire its outbound callback to L2CAP.
        val pm = PeerAudioManager()
        pm.init()
        pm.setCallback(object : PeerAudioManager.AudioCallback {
            override fun onMixedAudioReady(macAddress: String, opusData: ByteArray, seq: Int) {
                if (firstEncodedFramePeers.add(macAddress)) {
                    sendEventToFlutter(mapOf(
                        "type" to "firstEncodedFrame",
                        "address" to macAddress,
                    ))
                }
                val frame = buildVoiceFrame(opusData, seq)
                if (isVoiceHost) {
                    voiceTransport?.sendToClient(macAddress, frame)
                } else {
                    voiceTransport?.sendToHost(frame)
                }
            }
            override fun onTalkingPeersChanged(peers: Set<String>) {
                sendEventToFlutter(mapOf(
                    "type" to "talkingPeers",
                    "peers" to peers.toList()
                ))
            }
        })
        pm.startMixerThread()
        peerAudioManager = pm
        return true
    }

    private fun stopVoiceCapture() {
        Log.i(TAG, "Stopping voice capture")
        audioRoutingManager?.stopAutoDetect()
        peerAudioManager?.stopMixerThread()
        peerAudioManager?.clear()
        peerAudioManager = null

        val service = WalkieTalkieService.getRunning()
        service?.setLoopbackTestMode(false)
        service?.stopAudioEngine()

        audioMixerManager?.clear()
        audioMixerManager = null
        firstEncodedFramePeers.clear()
        firstDecodedFramePeers.clear()
        voiceSessionId++  // invalidate any in-flight registerVoicePeer retries
        // Stop and release the L2CAP transport so stale sockets
        // don't bleed into the next session (Dart has no separate
        // stopVoiceTransport call-site in the room exit path).
        voiceTransport?.stop()
        voiceTransport = null
        isVoiceHost = false
    }

    // Parse the 8-byte VoiceFrame header and push the Opus payload into the
    // native peer manager. Drops silently on malformed or oversized frames.
    private fun dispatchVoiceFrame(addr: String, frameBytes: ByteArray) {
        if (frameBytes.size < 8) return
        val seq = ((frameBytes[0].toInt() and 0xFF) shl 24) or
                  ((frameBytes[1].toInt() and 0xFF) shl 16) or
                  ((frameBytes[2].toInt() and 0xFF) shl 8) or
                  (frameBytes[3].toInt() and 0xFF)
        val opusPayload = frameBytes.copyOfRange(8, frameBytes.size)
        if (firstDecodedFramePeers.add(addr)) {
            sendEventToFlutter(mapOf("type" to "firstDecodedFrame", "address" to addr))
        }
        peerAudioManager?.onVoiceFrameReceived(addr, opusPayload, seq.toLong() and 0xFFFFFFFFL)
    }

    // Register addr as a peer in the native manager and add its mixer slot.
    // Retries up to 5 times (at 200 ms intervals) if peerAudioManager hasn't
    // been created yet — guards the race where the L2CAP channel opens before
    // startVoice has completed on the main thread.
    //
    // sessionId is captured at the call site so pending retries from a prior
    // session become no-ops once stopVoice increments voiceSessionId.
    private fun registerVoicePeer(addr: String, attempt: Int = 0, sessionId: Int = voiceSessionId) {
        if (sessionId != voiceSessionId) return  // stale retry from previous session
        val pm = peerAudioManager
        if (pm == null) {
            if (attempt < 5) {
                Handler(Looper.getMainLooper()).postDelayed(
                    { registerVoicePeer(addr, attempt + 1, sessionId) },
                    200,
                )
            } else {
                Log.e(TAG, "registerVoicePeer: peerAudioManager null after $attempt retries; $addr lost")
            }
            return
        }
        val deviceId = pm.registerPeer(addr)
        if (deviceId >= 0) {
            audioMixerManager?.addDevice(deviceId)
        }
    }

    // Encode [opusData] + [seq] into the 8-byte VoiceFrame wire format (big-endian).
    private fun buildVoiceFrame(opusData: ByteArray, seq: Int): ByteArray {
        val ts = (System.currentTimeMillis() and 0xFFFFFFFFL).toInt()
        val frame = ByteArray(8 + opusData.size)
        frame[0] = ((seq ushr 24) and 0xFF).toByte()
        frame[1] = ((seq ushr 16) and 0xFF).toByte()
        frame[2] = ((seq ushr 8) and 0xFF).toByte()
        frame[3] = (seq and 0xFF).toByte()
        frame[4] = ((ts ushr 24) and 0xFF).toByte()
        frame[5] = ((ts ushr 16) and 0xFF).toByte()
        frame[6] = ((ts ushr 8) and 0xFF).toByte()
        frame[7] = (ts and 0xFF).toByte()
        System.arraycopy(opusData, 0, frame, 8, opusData.size)
        return frame
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

    // Re-attach the MediaSession bridge on resume so a notification-access grant
    // that happened while the user was in system settings takes effect immediately.
    override fun onResume() {
        super.onResume()
        mediaSessionBridge?.attach()
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
            return
        }
        val freq = extractInviteFreq(intent)
        if (freq != null) {
            Log.i(TAG, "Invite deep link received (warm start): freq=$freq")
            sendEventToFlutter(mapOf("type" to "openInviteLink", "freq" to freq))
        }
    }

    private fun extractInviteFreq(intent: Intent): String? {
        val uri: Uri = intent.data ?: return null
        if (uri.scheme != "walkietalkie" || uri.host != "join") return null
        return uri.getQueryParameter("freq")
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
        mediaSessionBridge?.detach()
        mediaSessionBridge = null
        audioRoutingManager?.cleanup()
        bluetoothManager?.cleanup()
        peerAudioManager?.clear()
        peerAudioManager = null
        audioMixerManager?.clear()
        audioMixerManager = null
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
