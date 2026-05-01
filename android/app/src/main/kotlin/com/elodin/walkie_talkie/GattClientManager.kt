package com.elodin.walkie_talkie

import android.bluetooth.*
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

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
        private const val GATT_INSUFFICIENT_AUTHORIZATION = 8
        private const val GATT_INSUFFICIENT_AUTHENTICATION = 5
        private const val GATT_INSUFFICIENT_ENCRYPTION = 15

        /**
         * Number of *additional* connect attempts after the initial one that
         * we'll schedule on a transient GATT error. Total attempts =
         * 1 (initial) + MAX_CONNECT_RETRIES.
         */
        private const val MAX_CONNECT_RETRIES = 5

        /**
         * Status codes worth retrying on Samsung/OEM stacks: 133 (GATT_ERROR),
         * 147 (GATT_CONN_TIMEOUT), 8 (GATT_INSUFFICIENT_AUTHORIZATION — kept
         * here for byte parity but actually short-circuits in the auth branch
         * above), 19 (GATT_CONN_TERMINATE_PEER_USER on flaky links).
         */
        private val TRANSIENT_GATT_ERRORS = setOf(133, 147, 19)

        /**
         * Authorization-related GATT status codes that indicate permission
         * denial and should not be retried.
         */
        private val AUTHORIZATION_ERRORS = setOf(
            GATT_INSUFFICIENT_AUTHORIZATION,
            GATT_INSUFFICIENT_AUTHENTICATION,
            GATT_INSUFFICIENT_ENCRYPTION
        )
    }

    private var gatt: BluetoothGatt? = null
    private var requestCharacteristic: BluetoothGattCharacteristic? = null
    private var responseCharacteristic: BluetoothGattCharacteristic? = null
    private var connectRetryCount = 0
    private var pendingMacAddress: String? = null

    // ATT MTU negotiated for the connected host, keyed by MAC. Populated by
    // [onMtuChanged] once the GATT layer answers our [requestMtu] from
    // [onConnectionStateChange]. The Dart control transport reads this via
    // `MainActivity.getNegotiatedMtu` to size fragments to the actual link
    // budget; without it the guest side would always return null and never
    // engage MTU-aware fragmentation.
    private val negotiatedMtus: MutableMap<String, Int> = mutableMapOf()

    // Retries are scheduled via a Handler.postDelayed so the GATT callback
    // thread isn't blocked. The Runnable is cached so [disconnect] (and a
    // successful reconnect) can cancel any pending retry — otherwise a
    // user-initiated disconnect could be followed seconds later by a stale
    // reconnect attempt, leaking GATT state and confusing the Dart layer.
    private val retryHandler = Handler(Looper.getMainLooper())
    private var pendingRetry: Runnable? = null

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(
            gatt: BluetoothGatt,
            status: Int,
            newState: Int
        ) {
            // Check for authorization/authentication/encryption failures
            if (status in AUTHORIZATION_ERRORS) {
                Log.e(TAG, "GATT authorization failure: status=$status")
                onError?.invoke("GATT_AUTHORIZATION_DENIED")
                negotiatedMtus.remove(gatt.device.address)
                if (this@GattClientManager.gatt === gatt) {
                    this@GattClientManager.gatt = null
                }
                cancelPendingRetry()
                connectRetryCount = 0
                pendingMacAddress = null
                gatt.close()
                requestCharacteristic = null
                responseCharacteristic = null
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
            // Proceed to service discovery regardless of MTU result
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Service discovery failed with status $status")
                return
            }

            val service = gatt.getService(GattConstants.SERVICE_UUID)
            if (service == null) {
                Log.e(TAG, "Walkie-talkie service not found on host")
                return
            }

            // Cache the REQUEST characteristic for writes
            requestCharacteristic = service.getCharacteristic(GattConstants.REQUEST_CHAR_UUID)
            if (requestCharacteristic == null) {
                Log.e(TAG, "REQUEST characteristic not found")
                return
            }

            // Cache and enable notifications on RESPONSE characteristic
            responseCharacteristic = service.getCharacteristic(GattConstants.RESPONSE_CHAR_UUID)
            if (responseCharacteristic == null) {
                Log.e(TAG, "RESPONSE characteristic not found")
                return
            }

            // Enable local notifications
            val notifyEnabled = gatt.setCharacteristicNotification(responseCharacteristic, true)
            if (!notifyEnabled) {
                Log.e(TAG, "Failed to enable characteristic notification")
                return
            }

            // Write CCCD descriptor to enable notifications on the server side
            val cccd = responseCharacteristic?.getDescriptor(GattConstants.CCCD_UUID)
            if (cccd == null) {
                Log.e(TAG, "CCCD descriptor not found on RESPONSE characteristic")
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
            } else {
                Log.i(TAG, "GATT client setup complete, notifications enabled")
            }
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
                } else {
                    // Check for authorization failures on descriptor writes
                    if (status in AUTHORIZATION_ERRORS) {
                        Log.e(TAG, "CCCD write authorization failure: status=$status")
                        onError?.invoke("GATT_AUTHORIZATION_DENIED")
                        disconnect()
                    } else {
                        Log.e(TAG, "CCCD write failed with status $status")
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
                    if (status in AUTHORIZATION_ERRORS) {
                        Log.e(TAG, "REQUEST write authorization failure: status=$status")
                        onError?.invoke("GATT_AUTHORIZATION_DENIED")
                        // Disconnect and clean up since we've lost authorization
                        disconnect()
                    } else {
                        Log.w(TAG, "REQUEST write failed with status $status")
                    }
                }
            }
        }
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
    fun connectToHost(macAddress: String): Boolean {
        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        if (bluetoothManager == null) {
            Log.e(TAG, "BluetoothManager not available")
            return false
        }

        val adapter = bluetoothManager.adapter
        if (adapter == null) {
            Log.e(TAG, "BluetoothAdapter not available")
            return false
        }

        try {
            val device = adapter.getRemoteDevice(macAddress)
            Log.i(TAG, "Connecting to host at $macAddress (attempt ${connectRetryCount + 1})")
            pendingMacAddress = macAddress
            gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            return gatt != null
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
        val char = requestCharacteristic
        if (char == null) {
            Log.w(TAG, "Cannot write REQUEST: characteristic not available")
            return false
        }

        val currentGatt = gatt
        if (currentGatt == null) {
            Log.w(TAG, "Cannot write REQUEST: GATT connection not available")
            return false
        }

        try {
            // API 33+ writeCharacteristic with explicit value and writeType parameters
            val result = currentGatt.writeCharacteristic(
                char,
                bytes,
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            )
            val success = result == BluetoothStatusCodes.SUCCESS
            if (!success) {
                Log.w(TAG, "Failed to queue REQUEST write: $result")
            }
            return success
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing Bluetooth permissions for writeCharacteristic", e)
            onError?.invoke("BLUETOOTH_PERMISSION_DENIED")
            return false
        } catch (e: Exception) {
            Log.e(TAG, "Error writing REQUEST characteristic", e)
            return false
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
            connectRetryCount = 0
            pendingMacAddress = null
            gatt?.disconnect()
            Log.i(TAG, "GATT client disconnect initiated")
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
     * Check if currently connected to a host.
     */
    fun isConnected(): Boolean {
        return gatt != null && requestCharacteristic != null && responseCharacteristic != null
    }
}
