package com.elodin.walkie_talkie

import android.bluetooth.*
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * GATT client manager for the guest side of the Frequency control plane.
 *
 * Guests connect to the host's GATT server, discover the REQUEST (write) and
 * RESPONSE (notify) characteristics, enable notifications on RESPONSE, and
 * write protocol messages to REQUEST. The host emits JoinAccepted /
 * RosterUpdate / Heartbeat via RESPONSE notifications.
 *
 * Counterpart to GattServerManager (host side). Per docs/protocol.md § "GATT service".
 *
 * Wire-level UUIDs and the target ATT MTU live in [GattConstants] — the
 * single source of truth shared with the server side and the L2CAP transport.
 */
class GattClientManager(
    private val context: Context,
    private val onResponseBytes: (bytes: ByteArray) -> Unit,
    private val onError: ((String) -> Unit)? = null
) {
    companion object {
        private const val TAG = "GattClientManager"

        /**
         * Number of *additional* connect attempts after the initial one that
         * we'll schedule on a transient GATT error. Total attempts =
         * 1 (initial) + MAX_CONNECT_RETRIES.
         */
        private const val MAX_CONNECT_RETRIES = 5

        /**
         * Status codes worth retrying on Samsung/OEM stacks: 133 (GATT_ERROR),
         * 147 (GATT_CONN_TIMEOUT), 19 (GATT_CONN_TERMINATE_PEER_USER on flaky
         * links). Authorization errors (8, 5, 15) are handled separately via
         * GattConstants.AUTHORIZATION_ERRORS and are never retried.
         */
        private val TRANSIENT_GATT_ERRORS = setOf(133, 147, 19)

        // Poll RSSI at 5 s so the cache is fresh when SignalReport fires at 10 s.
        private const val RSSI_POLL_MS = 5_000L
    }

    private var gatt: BluetoothGatt? = null
    private var requestCharacteristic: BluetoothGattCharacteristic? = null
    private var responseCharacteristic: BluetoothGattCharacteristic? = null
    private var connectRetryCount = 0

    // True once the control link is fully ready to write: services discovered,
    // REQUEST/RESPONSE characteristics cached, and the RESPONSE CCCD write
    // confirmed (notifications active). connectToHost() returns at connection
    // *initiation*, well before this point, so the guest's first JoinRequest
    // can race ahead of a writable characteristic. Reset on every fresh connect.
    // @Volatile: written from the binder callback thread (onDescriptorWrite,
    // STATE_DISCONNECTED) and read on the main thread ([pumpOutboundWrites]).
    @Volatile
    private var controlReady = false
    // Serialized outbound REQUEST write queue. Android GATT permits only ONE
    // outstanding write per connection: firing the next write before the
    // previous one's [onCharacteristicWrite] callback returns
    // ERROR_GATT_WRITE_REQUEST_BUSY (201) and silently drops it. We enqueue
    // here and pump one at a time, advancing on each write callback. This also
    // covers writes that arrive before [controlReady] (e.g. the guest's first
    // JoinRequest, which races ahead of service discovery) — they sit in the
    // queue and drain in order once the link is ready, so the host always
    // receives the JoinRequest and can answer with JoinAccepted. All access is
    // confined to the main thread via [mainHandler] to avoid data races between
    // the binder callback thread and the method-channel caller thread.
    private val outboundWrites = ArrayDeque<ByteArray>()
    private var writeInFlight = false
    private var pendingMacAddress: String? = null
    @Volatile
    private var connectCallback: ((Boolean) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Fire the pending connect callback exactly once, on the main thread. */
    private fun finishConnect(success: Boolean) {
        mainHandler.post {
            val cb = connectCallback
            connectCallback = null
            cb?.invoke(success)
        }
    }

    // ATT MTU negotiated for the connected host, keyed by MAC. Populated by
    // [onMtuChanged] once the GATT layer answers our [requestMtu] from
    // [onConnectionStateChange]. The Dart control transport reads this via
    // `MainActivity.getNegotiatedMtu` to size fragments to the actual link
    // budget; without it the guest side would always return null and never
    // engage MTU-aware fragmentation.
    private val negotiatedMtus: MutableMap<String, Int> = mutableMapOf()

    // Latest RSSI sample per host MAC, populated by [onReadRemoteRssi].
    // ConcurrentHashMap: written on the GATT callback thread, read on the
    // MethodChannel (main) thread by getLatestRssiSamples().
    private val latestRssi = ConcurrentHashMap<String, Int>()

    // Retries are scheduled via a Handler.postDelayed so the GATT callback
    // thread isn't blocked. The Runnable is cached so [disconnect] (and a
    // successful reconnect) can cancel any pending retry — otherwise a
    // user-initiated disconnect could be followed seconds later by a stale
    // reconnect attempt, leaking GATT state and confusing the Dart layer.
    private val retryHandler = Handler(Looper.getMainLooper())
    private var pendingRetry: Runnable? = null

    // Periodic RSSI sampler — calls readRemoteRssi every RSSI_POLL_MS while
    // the link is up so the cache stays fresh for getCurrentRssi().
    private val rssiHandler = Handler(Looper.getMainLooper())
    private var rssiRunnable: Runnable? = null

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(
            gatt: BluetoothGatt,
            status: Int,
            newState: Int
        ) {
            // Check for authorization/authentication/encryption failures
            if (status in GattConstants.AUTHORIZATION_ERRORS) {
                Log.e(TAG, "GATT authorization failure: status=$status")
                onError?.invoke("GATT_AUTHORIZATION_DENIED")
                negotiatedMtus.remove(gatt.device.address)
                latestRssi.remove(gatt.device.address)
                if (this@GattClientManager.gatt === gatt) {
                    this@GattClientManager.gatt = null
                }
                cancelPendingRetry()
                stopRssiPolling()
                connectRetryCount = 0
                pendingMacAddress = null
                gatt.close()
                requestCharacteristic = null
                responseCharacteristic = null
                finishConnect(false)
                return
            }

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "Connected to GATT server: ${gatt.device.address}")
                    // Connection succeeded — drop any pending retry and reset
                    // the retry counter so the next failure starts fresh.
                    cancelPendingRetry()
                    connectRetryCount = 0
                    // Request MTU increase for better throughput
                    gatt.requestMtu(GattConstants.TARGET_ATT_MTU)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    val address = gatt.device.address
                    Log.i(TAG, "Disconnected from GATT server: $address, status=$status")

                    stopRssiPolling()
                    latestRssi.remove(address)

                    // Close the GATT connection here instead of in disconnect()
                    // to avoid closing before the callback completes, which
                    // triggers GATT 133 spam on Samsung stacks.
                    gatt.close()
                    if (this@GattClientManager.gatt === gatt) {
                        this@GattClientManager.gatt = null
                    }
                    negotiatedMtus.remove(address)
                    requestCharacteristic = null
                    responseCharacteristic = null
                    // Link is gone: mark it unwritable and drop any in-flight /
                    // queued writes so they can't leak onto a retried link.
                    // controlReady is @Volatile (safe from this binder thread);
                    // the queue is main-thread-confined, so clear it via the
                    // handler.
                    controlReady = false
                    mainHandler.post {
                        writeInFlight = false
                        outboundWrites.clear()
                    }

                    // Retry on transient GATT errors, but only while the
                    // user still wants to be connected (pendingMacAddress
                    // is cleared by disconnect()).
                    val mac = pendingMacAddress
                    if (mac != null &&
                        status in TRANSIENT_GATT_ERRORS &&
                        connectRetryCount < MAX_CONNECT_RETRIES
                    ) {
                        connectRetryCount++
                        val backoffMs = 100L * (1 shl (connectRetryCount - 1)) // exponential backoff
                        Log.w(TAG, "Transient GATT error $status, retry $connectRetryCount/$MAX_CONNECT_RETRIES after ${backoffMs}ms")

                        scheduleRetry(mac, backoffMs)
                    } else {
                        if (status != BluetoothGatt.GATT_SUCCESS) {
                            Log.e(TAG, "GATT disconnected with error status $status")
                            // Surface the failure to Flutter so the cubit's
                            // reconnect watchdog / UI can react instead of
                            // sitting silently in a half-broken state.
                            onError?.invoke("GATT_DISCONNECTED:$status")
                        }
                        cancelPendingRetry()
                        connectRetryCount = 0
                        pendingMacAddress = null
                        finishConnect(false)
                    }
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.i(TAG, "MTU changed to $mtu")
                negotiatedMtus[gatt.device.address] = mtu
            } else {
                Log.w(TAG, "MTU change failed with status $status")
            }
            // Proceed to service discovery regardless of MTU result.
            // If the stack refuses the request, propagate the failure so Flutter
            // can react (the onServicesDiscovered callback will never fire).
            // SecurityException is thrown if BLUETOOTH_CONNECT is revoked mid-session.
            try {
                val started = gatt.discoverServices()
                if (!started) {
                    Log.e(TAG, "discoverServices() returned false — GATT stack busy or disconnected")
                    onError?.invoke("GATT_SETUP_FAILED")
                    finishConnect(false)
                    gatt.disconnect()
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Missing Bluetooth permission for discoverServices()", e)
                onError?.invoke("BLUETOOTH_PERMISSION_DENIED")
                finishConnect(false)
                gatt.disconnect()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Service discovery failed with status $status")
                if (status in GattConstants.AUTHORIZATION_ERRORS) {
                    onError?.invoke("GATT_AUTHORIZATION_DENIED")
                } else {
                    onError?.invoke("GATT_SETUP_FAILED")
                }
                finishConnect(false)
                gatt.disconnect()
                return
            }

            val service = gatt.getService(GattConstants.SERVICE_UUID)
            if (service == null) {
                Log.e(TAG, "Walkie-talkie service not found on host")
                onError?.invoke("GATT_SETUP_FAILED")
                finishConnect(false)
                gatt.disconnect()
                return
            }

            // Cache the REQUEST characteristic for writes
            requestCharacteristic = service.getCharacteristic(GattConstants.REQUEST_CHAR_UUID)
            if (requestCharacteristic == null) {
                Log.e(TAG, "REQUEST characteristic not found")
                onError?.invoke("GATT_SETUP_FAILED")
                finishConnect(false)
                gatt.disconnect()
                return
            }

            // Cache and enable notifications on RESPONSE characteristic
            responseCharacteristic = service.getCharacteristic(GattConstants.RESPONSE_CHAR_UUID)
            if (responseCharacteristic == null) {
                Log.e(TAG, "RESPONSE characteristic not found")
                onError?.invoke("GATT_SETUP_FAILED")
                finishConnect(false)
                gatt.disconnect()
                return
            }

            // Enable local notifications
            val notifyEnabled = gatt.setCharacteristicNotification(responseCharacteristic, true)
            if (!notifyEnabled) {
                Log.e(TAG, "Failed to enable characteristic notification")
                onError?.invoke("GATT_SETUP_FAILED")
                finishConnect(false)
                gatt.disconnect()
                return
            }

            // Write CCCD descriptor to enable notifications on the server side
            val cccd = responseCharacteristic?.getDescriptor(GattConstants.CCCD_UUID)
            if (cccd == null) {
                Log.e(TAG, "CCCD descriptor not found on RESPONSE characteristic")
                onError?.invoke("GATT_SETUP_FAILED")
                finishConnect(false)
                gatt.disconnect()
                return
            }

            // API 33+ writeDescriptor with explicit value parameter — avoids
            // the deprecated 2-arg form whose `desc.value` field could go
            // stale before the write actually flushed.
            val writeSuccess = gatt.writeDescriptor(
                cccd,
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            )
            if (writeSuccess != BluetoothStatusCodes.SUCCESS) {
                Log.e(TAG, "Failed to write CCCD descriptor: $writeSuccess")
                onError?.invoke("GATT_SETUP_FAILED")
                finishConnect(false)
                gatt.disconnect()
            } else {
                Log.i(TAG, "GATT client setup complete, notifications enabled")
            }
            // RSSI polling starts in onDescriptorWrite once the CCCD write is confirmed
            // so we don't overlap in-flight GATT operations.
        }

        // API 33+ onCharacteristicChanged with explicit value parameter — the
        // 2-arg form returns characteristic.value which can be overwritten by
        // a subsequent notification before the callback reads it.
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (characteristic.uuid == GattConstants.RESPONSE_CHAR_UUID) {
                if (value.isNotEmpty()) {
                    Log.d(TAG, "Received ${value.size} bytes from host")
                    onResponseBytes(value)
                } else {
                    Log.w(TAG, "Received empty RESPONSE notification")
                }
            }
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            if (descriptor.uuid == GattConstants.CCCD_UUID) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    Log.i(TAG, "CCCD write successful, notifications active")
                    // Link is now fully ready: services discovered, characteristics
                    // cached, notifications enabled. Flush any REQUEST writes that
                    // raced ahead of discovery (the guest's first JoinRequest) so
                    // the host receives them and can answer with JoinAccepted.
                    controlReady = true
                    // Drain any writes that raced ahead of discovery (the
                    // guest's first JoinRequest), serialized through the
                    // single GATT write slot.
                    mainHandler.post { pumpOutboundWrites() }
                    // CCCD confirmed — GATT is fully idle, safe to start RSSI polling.
                    startRssiPolling()
                    finishConnect(true)
                } else {
                    // Check for authorization failures on descriptor writes
                    if (status in GattConstants.AUTHORIZATION_ERRORS) {
                        Log.e(TAG, "CCCD write authorization failure: status=$status")
                        onError?.invoke("GATT_AUTHORIZATION_DENIED")
                        finishConnect(false)
                        disconnect()
                    } else {
                        Log.e(TAG, "CCCD write failed with status $status")
                        onError?.invoke("GATT_SETUP_FAILED")
                        finishConnect(false)
                        disconnect()
                    }
                }
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            if (characteristic.uuid == GattConstants.REQUEST_CHAR_UUID) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    Log.d(TAG, "REQUEST write successful")
                } else {
                    // Check for authorization failures on write operations
                    if (status in GattConstants.AUTHORIZATION_ERRORS) {
                        Log.e(TAG, "REQUEST write authorization failure: status=$status")
                        onError?.invoke("GATT_AUTHORIZATION_DENIED")
                        // Disconnect and clean up since we've lost authorization
                        disconnect()
                        return
                    }
                    Log.w(TAG, "REQUEST write failed with status $status")
                }
                // This write slot is free — advance the serialized queue
                // regardless of success/failure so one dropped write doesn't
                // stall every subsequent one.
                mainHandler.post {
                    writeInFlight = false
                    pumpOutboundWrites()
                }
            }
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                latestRssi[gatt.device.address] = rssi
                Log.d(TAG, "RSSI for ${gatt.device.address}: $rssi dBm")
            } else {
                Log.w(TAG, "readRemoteRssi failed: status=$status")
            }
        }
    }

    private fun startRssiPolling() {
        stopRssiPolling()
        val runnable = object : Runnable {
            override fun run() {
                val currentGatt = gatt ?: return
                try {
                    val queued = currentGatt.readRemoteRssi()
                    if (!queued) {
                        Log.w(TAG, "readRemoteRssi: GATT busy, will retry next tick")
                    }
                } catch (e: SecurityException) {
                    Log.w(TAG, "Missing permission for readRemoteRssi — stopping RSSI polling", e)
                    stopRssiPolling()
                    onError?.invoke("BLUETOOTH_PERMISSION_DENIED")
                    return
                }
                rssiHandler.postDelayed(this, RSSI_POLL_MS)
            }
        }
        rssiRunnable = runnable
        rssiHandler.postDelayed(runnable, RSSI_POLL_MS)
    }

    private fun stopRssiPolling() {
        rssiRunnable?.let(rssiHandler::removeCallbacks)
        rssiRunnable = null
    }

    private fun scheduleRetry(macAddress: String, delayMs: Long) {
        cancelPendingRetry()
        val runnable = Runnable {
            // The user may have called disconnect() during the backoff
            // window — re-check before initiating a new connectGatt.
            if (pendingMacAddress == macAddress) {
                connectToHost(macAddress)
            }
        }
        pendingRetry = runnable
        retryHandler.postDelayed(runnable, delayMs)
    }

    private fun cancelPendingRetry() {
        pendingRetry?.let(retryHandler::removeCallbacks)
        pendingRetry = null
    }

    /**
     * Connect to the host's GATT server at [macAddress].
     *
     * Returns true if the connection attempt was initiated, false otherwise.
     * Actual connection state changes are reported via the callback.
     */
    fun connectToHost(macAddress: String, callback: ((Boolean) -> Unit)? = null): Boolean {
        if (callback != null) {
            val oldCb = this.connectCallback
            this.connectCallback = null
            oldCb?.let {
                mainHandler.post { it(false) }
            }
            this.connectCallback = callback
        }

        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        if (bluetoothManager == null) {
            Log.e(TAG, "BluetoothManager not available")
            finishConnect(false)
            return false
        }

        val adapter = bluetoothManager.adapter
        if (adapter == null) {
            Log.e(TAG, "BluetoothAdapter not available")
            finishConnect(false)
            return false
        }

        // Fresh attempt: the new link isn't writable until its CCCD write
        // confirms. Reset readiness and drop any writes left over from a prior
        // link so they can't flush onto this one.
        controlReady = false
        outboundWrites.clear()
        writeInFlight = false

        // Close any existing GATT reference to prevent resource leaks
        val oldGatt = gatt
        if (oldGatt != null) {
            Log.i(TAG, "Closing existing BluetoothGatt before new connection attempt")
            try {
                oldGatt.disconnect()
                oldGatt.close()
            } catch (e: Exception) {
                Log.w(TAG, "Error closing old BluetoothGatt", e)
            }
            gatt = null
        }

        try {
            val device = adapter.getRemoteDevice(macAddress)
            Log.i(TAG, "Connecting to host at $macAddress (attempt ${connectRetryCount + 1})")
            pendingMacAddress = macAddress
            gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            val success = gatt != null
            if (!success) {
                finishConnect(false)
            }
            return success
        } catch (e: Exception) {
            // Reset retry / pending state on every failure path so a half-set
            // pendingMacAddress can't trigger a retry the user never asked for.
            when (e) {
                is SecurityException -> {
                    Log.e(TAG, "Missing Bluetooth permissions for connectGatt", e)
                    onError?.invoke("BLUETOOTH_PERMISSION_DENIED")
                }
                is IllegalArgumentException ->
                    Log.e(TAG, "Invalid MAC address: $macAddress", e)
                else ->
                    Log.e(TAG, "Error connecting to GATT server", e)
            }
            cancelPendingRetry()
            connectRetryCount = 0
            pendingMacAddress = null
            finishConnect(false)
            return false
        }
    }

    /**
     * Write bytes to the REQUEST characteristic.
     *
     * Used by guests to send JoinRequest, MediaCommand, Leave, etc. to the host.
     * Returns true if the write was queued, false otherwise.
     */
    fun writeRequest(bytes: ByteArray): Boolean {
        // Enqueue on the main thread and let [pumpOutboundWrites] drive the
        // single GATT write slot. The link isn't writable until service
        // discovery + the CCCD write complete (see [controlReady]);
        // connectToHost() returns at connection *initiation*, so callers —
        // notably the guest's first JoinRequest — can race ahead of a writable
        // characteristic. The queue holds those writes until the link is ready
        // and then drains them in order, one outstanding write at a time, so
        // none are dropped and the host always receives the JoinRequest.
        mainHandler.post {
            outboundWrites.add(bytes)
            pumpOutboundWrites()
        }
        return true
    }

    /**
     * Send the next queued REQUEST write if the link is ready and no write is
     * already in flight. Android GATT allows only one outstanding write per
     * connection; issuing the next before the previous [onCharacteristicWrite]
     * callback returns ERROR_GATT_WRITE_REQUEST_BUSY (201) and the write is
     * lost. Re-invoked from [onCharacteristicWrite] to drain the queue in
     * order. Main-thread only.
     */
    private fun pumpOutboundWrites() {
        if (!controlReady || writeInFlight) return
        val bytes = outboundWrites.firstOrNull() ?: return

        val char = requestCharacteristic
        val currentGatt = gatt
        if (char == null || currentGatt == null) {
            Log.w(TAG, "Cannot write REQUEST: link not available; ${outboundWrites.size} queued")
            return
        }

        try {
            // API 33+ writeCharacteristic with explicit value and writeType parameters
            val result = currentGatt.writeCharacteristic(
                char,
                bytes,
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            )
            if (result == BluetoothStatusCodes.SUCCESS) {
                outboundWrites.removeFirst()
                writeInFlight = true
            } else {
                // Stack momentarily busy (e.g. 201): keep the write at the head
                // and retry shortly rather than dropping it.
                Log.w(TAG, "REQUEST write not accepted ($result) — retrying in 20ms")
                mainHandler.postDelayed({ pumpOutboundWrites() }, 20)
            }
        } catch (e: SecurityException) {
            // Drop the head write: writeInFlight stays false and
            // onCharacteristicWrite won't fire (no write was issued), so
            // leaving it queued would make every future pump retry the same
            // doomed write and permanently stall the queue.
            Log.e(TAG, "Missing Bluetooth permissions for writeCharacteristic", e)
            outboundWrites.removeFirstOrNull()
            onError?.invoke("BLUETOOTH_PERMISSION_DENIED")
        } catch (e: Exception) {
            Log.e(TAG, "Error writing REQUEST characteristic", e)
            outboundWrites.removeFirstOrNull()
        }
    }

    /**
     * Disconnect from the host and clean up the GATT connection.
     *
     * Note: close() is called in the STATE_DISCONNECTED callback, not here,
     * to avoid closing the handle before the callback completes (which
     * triggers GATT 133 errors on Samsung stacks). The callback is also
     * responsible for nulling [gatt] and clearing the negotiated MTU
     * cache for the disconnected address.
     */
    fun disconnect() {
        try {
            cancelPendingRetry()
            stopRssiPolling()
            connectRetryCount = 0
            pendingMacAddress = null
            // controlReady is @Volatile; the write queue is main-thread-confined
            // (disconnect() may be invoked from a binder callback via onError).
            controlReady = false
            mainHandler.post {
                writeInFlight = false
                outboundWrites.clear()
            }
            val currentGatt = gatt
            if (currentGatt != null) {
                try {
                    currentGatt.disconnect()
                    currentGatt.close()
                } catch (e: Exception) {
                    // Ignore
                }
                gatt = null
            }
            Log.i(TAG, "GATT client disconnected and closed")
            finishConnect(false)
        } catch (e: Exception) {
            Log.e(TAG, "Error disconnecting GATT client", e)
        }
    }

    /**
     * Returns the ATT MTU negotiated for [endpointId] (host MAC), or null if
     * no MTU has been observed yet for that link. Mirrors
     * `GattServerManager.getMtu(endpointId)`; one side or the other answers
     * depending on which device is the GATT client/server for this link.
     */
    fun getMtu(endpointId: String): Int? = negotiatedMtus[endpointId]

    /**
     * Returns the latest RSSI samples as a list of maps for the Dart layer.
     * Each map contains "peerId" (host MAC address) and "rssi" (dBm, negative).
     * Returns an empty list if no samples have been collected yet.
     */
    fun getLatestRssiSamples(): List<Map<String, Any>> =
        latestRssi.entries.map { (mac, rssi) -> mapOf("peerId" to mac, "rssi" to rssi) }

    /**
     * Check if currently connected to a host.
     */
    fun isConnected(): Boolean {
        return gatt != null && requestCharacteristic != null && responseCharacteristic != null
    }
}
