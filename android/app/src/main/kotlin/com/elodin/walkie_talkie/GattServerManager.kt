package com.elodin.walkie_talkie

import android.bluetooth.*
import android.content.Context
import android.util.Log
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * GATT server manager for the Frequency control plane.
 *
 * Hosts expose REQUEST (write) and RESPONSE (notify) characteristics over
 * the walkie-talkie service UUID. Guests write JoinRequest / MediaCommand /
 * Leave messages to REQUEST; the host emits JoinAccepted / RosterUpdate /
 * Heartbeat messages via RESPONSE notifications.
 *
 * Per docs/protocol.md § "GATT service".
 */
class GattServerManager(
    private val context: Context,
    private val onBytesReceived: (deviceAddress: String, bytes: ByteArray) -> Unit
) {
    companion object {
        private const val TAG = "GattServerManager"

        val SERVICE_UUID: UUID = UUID.fromString("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e8e")
        val REQUEST_CHAR_UUID: UUID = UUID.fromString("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e01")
        val RESPONSE_CHAR_UUID: UUID = UUID.fromString("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e02")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private var gattServer: BluetoothGattServer? = null
    private val connectedDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val negotiatedMtus = ConcurrentHashMap<String, Int>()
    private lateinit var responseCharacteristic: BluetoothGattCharacteristic

    private val gattCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(
            device: BluetoothDevice,
            status: Int,
            newState: Int
        ) {
            val address = device.address
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "GATT connected: $address")
                    connectedDevices[address] = device
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "GATT disconnected: $address")
                    connectedDevices.remove(address)
                    negotiatedMtus.remove(address)
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            val address = device.address

            if (characteristic.uuid == REQUEST_CHAR_UUID) {
                if (value != null && value.isNotEmpty()) {
                    Log.d(TAG, "Received ${value.size} bytes from $address")
                    onBytesReceived(address, value)
                } else {
                    Log.w(TAG, "Empty write request from $address")
                }

                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_SUCCESS,
                        0,
                        null
                    )
                }
            } else {
                Log.w(TAG, "Write to unknown characteristic: ${characteristic.uuid}")
                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_WRITE_NOT_PERMITTED,
                        0,
                        null
                    )
                }
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            if (descriptor.uuid == CCCD_UUID) {
                val enabled = value?.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == true
                Log.i(TAG, "${device.address} ${if (enabled) "enabled" else "disabled"} notifications")

                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_SUCCESS,
                        0,
                        null
                    )
                }
            } else {
                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_WRITE_NOT_PERMITTED,
                        0,
                        null
                    )
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            val address = device.address
            Log.i(TAG, "MTU changed for $address: $mtu")
            negotiatedMtus[address] = mtu
        }
    }

    /**
     * Start the GATT server and advertise the service.
     */
    fun start(): Boolean {
        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        if (bluetoothManager == null) {
            Log.e(TAG, "BluetoothManager not available")
            return false
        }

        try {
            gattServer = bluetoothManager.openGattServer(context, gattCallback)
            if (gattServer == null) {
                Log.e(TAG, "Failed to open GATT server")
                return false
            }

            // Build the service with REQUEST and RESPONSE characteristics
            val service = BluetoothGattService(
                SERVICE_UUID,
                BluetoothGattService.SERVICE_TYPE_PRIMARY
            )

            // REQUEST characteristic: write + write-no-response
            val requestChar = BluetoothGattCharacteristic(
                REQUEST_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            service.addCharacteristic(requestChar)

            // RESPONSE characteristic: notify
            responseCharacteristic = BluetoothGattCharacteristic(
                RESPONSE_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )

            // Add CCCD descriptor for notifications
            val cccdDescriptor = BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_WRITE or
                BluetoothGattDescriptor.PERMISSION_READ
            )
            responseCharacteristic.addDescriptor(cccdDescriptor)
            service.addCharacteristic(responseCharacteristic)

            val added = gattServer?.addService(service) ?: false
            if (!added) {
                Log.e(TAG, "Failed to add GATT service")
                return false
            }

            Log.i(TAG, "GATT server started successfully")
            return true
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing Bluetooth permissions", e)
            return false
        } catch (e: Exception) {
            Log.e(TAG, "Error starting GATT server", e)
            return false
        }
    }

    /**
     * Send a notification to a specific device.
     *
     * Returns true if the notification was queued, false otherwise.
     * The actual transmission is async; errors are logged but not reported.
     */
    fun notify(deviceAddress: String, bytes: ByteArray): Boolean {
        val device = connectedDevices[deviceAddress]
        if (device == null) {
            Log.w(TAG, "Cannot notify $deviceAddress: not connected")
            return false
        }

        try {
            responseCharacteristic.value = bytes
            val success = gattServer?.notifyCharacteristicChanged(
                device,
                responseCharacteristic,
                false
            ) ?: false

            if (!success) {
                Log.w(TAG, "Failed to queue notification for $deviceAddress")
            }
            return success
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing Bluetooth permissions for notify", e)
            return false
        } catch (e: Exception) {
            Log.e(TAG, "Error sending notification to $deviceAddress", e)
            return false
        }
    }

    /**
     * Get the negotiated MTU for a specific device.
     * Returns null if no MTU has been negotiated (default 23 bytes).
     */
    fun getMtu(deviceAddress: String): Int? {
        return negotiatedMtus[deviceAddress]
    }

    /**
     * Get list of currently connected device addresses.
     */
    fun getConnectedAddresses(): List<String> {
        return connectedDevices.keys.toList()
    }

    /**
     * Stop the GATT server and clear all connections.
     */
    fun stop() {
        try {
            gattServer?.close()
            gattServer = null
            connectedDevices.clear()
            negotiatedMtus.clear()
            Log.i(TAG, "GATT server stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping GATT server", e)
        }
    }
}
