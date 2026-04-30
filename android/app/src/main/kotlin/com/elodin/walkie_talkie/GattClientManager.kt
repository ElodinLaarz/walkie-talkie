package com.elodin.walkie_talkie

import android.bluetooth.*
import android.content.Context
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
    }

    private var gatt: BluetoothGatt? = null
    private var requestCharacteristic: BluetoothGattCharacteristic? = null
    private var responseCharacteristic: BluetoothGattCharacteristic? = null

    // ATT MTU negotiated for the connected host, keyed by MAC. Populated by
    // [onMtuChanged] once the GATT layer answers our [requestMtu] from
    // [onConnectionStateChange]. The Dart control transport reads this via
    // `MainActivity.getNegotiatedMtu` to size fragments to the actual link
    // budget; without it the guest side would always return null and never
    // engage MTU-aware fragmentation.
    private val negotiatedMtus: MutableMap<String, Int> = mutableMapOf()

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(
            gatt: BluetoothGatt,
            status: Int,
            newState: Int
        ) {
            // Check for authorization/authentication failures
            if (status == GATT_INSUFFICIENT_AUTHORIZATION || status == GATT_INSUFFICIENT_AUTHENTICATION) {
                Log.e(TAG, "GATT authorization failure: status=$status")
                onError?.invoke("GATT_AUTHORIZATION_DENIED")
                negotiatedMtus.remove(gatt.device.address)
                if (this@GattClientManager.gatt === gatt) {
                    this@GattClientManager.gatt = null
                }
                gatt.close()
                requestCharacteristic = null
                responseCharacteristic = null
                return
            }

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "Connected to GATT server: ${gatt.device.address}")
                    // Request MTU increase for better throughput
                    gatt.requestMtu(GattConstants.TARGET_ATT_MTU)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "Disconnected from GATT server: ${gatt.device.address}")
                    requestCharacteristic = null
                    responseCharacteristic = null
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

            cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            val writeSuccess = gatt.writeDescriptor(cccd)
            if (!writeSuccess) {
                Log.e(TAG, "Failed to write CCCD descriptor")
            } else {
                Log.i(TAG, "GATT client setup complete, notifications enabled")
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == GattConstants.RESPONSE_CHAR_UUID) {
                val bytes = characteristic.value
                if (bytes != null && bytes.isNotEmpty()) {
                    Log.d(TAG, "Received ${bytes.size} bytes from host")
                    onResponseBytes(bytes)
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
                    Log.e(TAG, "CCCD write failed with status $status")
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
                    Log.w(TAG, "REQUEST write failed with status $status")
                }
            }
        }
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
            Log.i(TAG, "Connecting to host at $macAddress")
            gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            return gatt != null
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing Bluetooth permissions for connectGatt", e)
            onError?.invoke("BLUETOOTH_PERMISSION_DENIED")
            return false
        } catch (e: IllegalArgumentException) {
            Log.e(TAG, "Invalid MAC address: $macAddress", e)
            return false
        } catch (e: Exception) {
            Log.e(TAG, "Error connecting to GATT server", e)
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
            char.value = bytes
            char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            val success = currentGatt.writeCharacteristic(char)
            if (!success) {
                Log.w(TAG, "Failed to queue REQUEST write")
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
     */
    fun disconnect() {
        try {
            val address = gatt?.device?.address
            gatt?.disconnect()
            gatt?.close()
            gatt = null
            requestCharacteristic = null
            responseCharacteristic = null
            if (address != null) {
                negotiatedMtus.remove(address)
            }
            Log.i(TAG, "GATT client disconnected and closed")
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
