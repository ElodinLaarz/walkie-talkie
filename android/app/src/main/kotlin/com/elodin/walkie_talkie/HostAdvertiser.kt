package com.elodin.walkie_talkie

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID

/**
 * Host-side LE advertiser for the Frequency control plane.
 *
 * Broadcasts the walkie-talkie service UUID and a 16-byte manufacturer
 * payload (protocol version, role, low 8 bytes of sessionUuid, reserved
 * flags). Guests scanning with the same service UUID parse the payload
 * Dart-side in lib/protocol/discovery.dart.
 *
 * Per docs/protocol.md § "Bluetooth LE advertising".
 */
class HostAdvertiser(private val context: Context) {
    companion object {
        private const val TAG = "HostAdvertiser"

        // Same 128-bit UUID Dart guests filter on (see kWalkieTalkieServiceUuid
        // in lib/protocol/discovery.dart). Kept in sync with
        // GattServerManager.SERVICE_UUID — they're the same wire identifier.
        val SERVICE_UUID: UUID = GattServerManager.SERVICE_UUID

        // Test/internal manufacturer ID range (0xFFFF). Fine for v1; if we
        // ever ship with a real Bluetooth SIG company ID this is the single
        // place to swap it.
        private const val MANUFACTURER_ID = 0xFFFF

        private const val PROTOCOL_VERSION_V1: Byte = 0x01
        private const val ROLE_HOST: Byte = 0x01

        // Payload layout from docs/protocol.md § "Bluetooth LE advertising":
        //   [0]    protocol version (0x01 for v1)
        //   [1]    role (0x01 = host)
        //   [2..9] low 8 bytes of sessionUuid (big-endian)
        //   [10,11] flags (reserved, zero in v1)
        //   [12..15] reserved
        const val MANUFACTURER_PAYLOAD_SIZE = 16
    }

    private val bluetoothManager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager?.adapter

    private var advertiser: BluetoothLeAdvertiser? = null
    private var isAdvertising = false

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.i(TAG, "Advertising started: $settingsInEffect")
        }

        override fun onStartFailure(errorCode: Int) {
            // Reset the flag so a retry can re-issue startAdvertising. The
            // BluetoothLeAdvertiser doesn't surface the error any other way;
            // OEM-specific causes (chipset stuck, too many advertisers) just
            // log here and the caller observes a quiet wire.
            isAdvertising = false
            val reason = when (errorCode) {
                ADVERTISE_FAILED_ALREADY_STARTED -> "already started"
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "data too large"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "feature unsupported"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "internal error"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "too many advertisers"
                else -> "unknown ($errorCode)"
            }
            Log.e(TAG, "Advertising failed: $reason")
        }
    }

    /**
     * Start LE advertising the host's session.
     *
     * Idempotent: a second call while already advertising returns true
     * without re-issuing — the underlying [BluetoothLeAdvertiser] would
     * reject it with [AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED]
     * anyway, and treating that as success here matches the rest of the
     * native surface (start GATT server, start voice server).
     *
     * Returns false on any pre-flight failure: Bluetooth off, advertising
     * unsupported on the chipset, malformed [sessionUuid], or a
     * [SecurityException] from the missing BLUETOOTH_ADVERTISE permission.
     * Async failures from the OS arrive on the [advertiseCallback] and are
     * logged; callers see them indirectly through a quiet wire.
     */
    fun start(sessionUuid: String, displayName: String): Boolean {
        if (isAdvertising) {
            Log.i(TAG, "Already advertising; ignoring start request")
            return true
        }

        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            Log.e(TAG, "Bluetooth adapter unavailable or disabled")
            return false
        }

        val leAdvertiser = adapter.bluetoothLeAdvertiser
        if (leAdvertiser == null) {
            Log.e(TAG, "BluetoothLeAdvertiser unavailable (peripheral mode unsupported?)")
            return false
        }

        val payload = try {
            buildManufacturerPayload(sessionUuid)
        } catch (e: IllegalArgumentException) {
            Log.e(TAG, "Invalid sessionUuid: $sessionUuid", e)
            return false
        }

        // Including the device name pushes us close to the 31-byte legacy
        // adv frame budget when the user's name is long. Set it on the
        // adapter (the system truncates to fit) and let setIncludeDeviceName
        // handle the rest. Failing to set the name is non-fatal — guests
        // fall back to the manufacturer payload + host's BT MAC.
        try {
            adapter.setName(displayName)
        } catch (e: SecurityException) {
            Log.w(TAG, "Could not set adapter name (BLUETOOTH_CONNECT missing)", e)
        }

        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .addManufacturerData(MANUFACTURER_ID, payload)
            .setIncludeDeviceName(true)
            .build()

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        return try {
            leAdvertiser.startAdvertising(settings, data, advertiseCallback)
            advertiser = leAdvertiser
            isAdvertising = true
            Log.i(TAG, "Advertising start requested for session=$sessionUuid name=$displayName")
            true
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing BLUETOOTH_ADVERTISE permission", e)
            false
        } catch (e: Exception) {
            Log.e(TAG, "Error starting advertising", e)
            false
        }
    }

    /**
     * Stop LE advertising. Safe to call when not running.
     */
    fun stop() {
        val leAdvertiser = advertiser ?: return
        try {
            leAdvertiser.stopAdvertising(advertiseCallback)
            Log.i(TAG, "Advertising stopped")
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing Bluetooth permissions for stopAdvertising", e)
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping advertising", e)
        } finally {
            advertiser = null
            isAdvertising = false
        }
    }

    /**
     * Build the 16-byte manufacturer payload from the canonical session UUID
     * string. Throws [IllegalArgumentException] if [sessionUuid] is not a
     * valid UUID — callers should treat this as a programmer error
     * (the host cubit mints the UUID; a bad value means a regression upstream).
     *
     * Visible for the MainActivity wiring path; not part of the public API.
     */
    internal fun buildManufacturerPayload(sessionUuid: String): ByteArray {
        // UUID.fromString rejects any other shape; an IllegalArgumentException
        // bubbles to start() and turns into a logged false return.
        val uuid = UUID.fromString(sessionUuid)
        // The 64-bit "least significant bits" of a UUID *are* the low 8 bytes
        // in canonical big-endian order — that's how the docs/protocol.md
        // mhz derivation reads them on the guest side. Encode high byte first.
        val lsb = uuid.leastSignificantBits

        val payload = ByteArray(MANUFACTURER_PAYLOAD_SIZE)
        payload[0] = PROTOCOL_VERSION_V1
        payload[1] = ROLE_HOST
        for (i in 0..7) {
            payload[2 + i] = ((lsb ushr (56 - i * 8)) and 0xFFL).toByte()
        }
        // payload[10..15] stay zero: reserved flags + reserved bytes per spec.
        return payload
    }
}
