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

    // The advertiser handle and state flags are touched from both the caller
    // thread (start/stop on the platform main thread) and the OS-issued
    // AdvertiseCallback thread. Mark them @Volatile so the callback can't
    // observe a partially-published state and the caller can't race the
    // callback on the success/failure transition.
    @Volatile
    private var advertiser: BluetoothLeAdvertiser? = null

    @Volatile
    private var isAdvertising = false

    // Tracks the gap between issuing startAdvertising and the OS calling
    // back with success/failure. Without it, a fast caller could observe
    // isAdvertising=false right after a successful start() and re-issue,
    // tripping ADVERTISE_FAILED_ALREADY_STARTED on the second call.
    @Volatile
    private var isStarting = false

    // Captured before adapter.setName() so stop() can put the user's
    // device-wide BT name back. Null means we never changed it (start
    // bailed before mutating) or we already restored.
    @Volatile
    private var savedAdapterName: String? = null

    // The currently-active AdvertiseCallback. Each start() builds a fresh
    // callback (see [makeCallback]) and stores it here; stop() and any
    // failure path nulls it out. The callback's own methods compare
    // `currentCallback === this` before mutating any state so a late
    // event from a previous attempt — e.g. an onStartFailure that arrives
    // after the user has already left and rejoined — can't clobber the
    // new attempt's flags.
    @Volatile
    private var currentCallback: AdvertiseCallback? = null

    private fun makeCallback(): AdvertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            // Drop late events from a superseded attempt. Without this guard
            // a stale onStartSuccess could promote isAdvertising for the
            // *current* attempt that's still in its isStarting window, or
            // worse, after stop() already cleared everything.
            if (currentCallback !== this) return
            // Promote isStarting → isAdvertising only when the OS confirms
            // the radio is on the air. A premature flip in start() would let
            // a fire-and-forget caller (the cubit uses unawaited) treat a
            // later onStartFailure as success and never retry.
            isStarting = false
            isAdvertising = true
            Log.i(TAG, "Advertising started")
        }

        override fun onStartFailure(errorCode: Int) {
            if (currentCallback !== this) {
                // Swallow stale failures silently — the new attempt owns
                // state now. Logging the reason is fine, but only as debug.
                Log.d(TAG, "Stale advertising failure ignored: code=$errorCode")
                return
            }
            // Reset both flags + clear the advertiser handle so a retry can
            // re-issue startAdvertising. The BluetoothLeAdvertiser doesn't
            // surface the error any other way; OEM-specific causes (chipset
            // stuck, too many advertisers) just log here and the caller
            // observes a quiet wire.
            isStarting = false
            isAdvertising = false
            advertiser = null
            currentCallback = null
            // Best-effort restore of the user's BT name on async failure —
            // we may have set it already in the caller and the OS just
            // refused to advertise. Same SecurityException swallow as
            // restoreAdapterName().
            restoreAdapterName()
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
     * Idempotent: a second call while already advertising (or while the
     * first start is awaiting OS confirmation) returns true without
     * re-issuing — the underlying [BluetoothLeAdvertiser] would reject it
     * with [AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED] anyway,
     * and treating that as success here matches the rest of the native
     * surface (start GATT server, start voice server).
     *
     * Returns false on any pre-flight failure: Bluetooth off, advertising
     * unsupported on the chipset, malformed [sessionUuid], or a
     * [SecurityException] from the missing BLUETOOTH_ADVERTISE permission.
     * Async failures from the OS arrive on the per-attempt callback (built
     * by [makeCallback]) and are logged; callers see them indirectly through
     * a quiet wire. A `true` return therefore only means *the request was
     * accepted* — the callback is the single source of truth for whether
     * the radio is actually on the air.
     */
    fun start(sessionUuid: String, displayName: String): Boolean {
        if (isAdvertising || isStarting) {
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
            Log.e(TAG, "Invalid sessionUuid", e)
            return false
        }

        // Setting setIncludeDeviceName(true) below pulls the *adapter* name
        // into the adv frame; that's a system-wide setting that survives
        // process death. Capture the current value so stop() can put it
        // back — otherwise a Frequency host session would permanently
        // rename the user's phone in their Bluetooth settings. Skipping
        // the rename if it already matches avoids touching the adapter
        // when the user's existing BT name is already their display name.
        val previousName = try {
            adapter.name
        } catch (e: SecurityException) {
            // Read failure means we can't capture-then-restore — the rename
            // path will skip and the user's adapter name stays untouched.
            // Worth logging since silent restore-skips are otherwise invisible.
            Log.w(TAG, "Could not read adapter name; restore will be skipped", e)
            null
        }
        if (previousName != displayName) {
            try {
                adapter.setName(displayName)
                savedAdapterName = previousName
            } catch (e: SecurityException) {
                Log.w(TAG, "Could not set adapter name (BLUETOOTH_CONNECT missing)", e)
            }
        }

        // The 31-byte legacy ADV_IND budget can't fit *all* of: flags (auto),
        // 128-bit service UUID (18 bytes including header), 16-byte
        // manufacturer payload (20 bytes including header), and the adapter
        // device name. 18 + 20 alone overflows. Split across primary adv
        // (service UUID — keeps passive scanners able to filter) and scan
        // response (manufacturer payload + device name — only fetched on the
        // SCAN_REQ that active scanners issue, which is what the Dart
        // DiscoveryService does). The Android stack merges both records into
        // ScanRecord, so DiscoveredSession.fromManufacturerData reassembles
        // them transparently.
        val advData = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        val scanResponse = AdvertiseData.Builder()
            .addManufacturerData(MANUFACTURER_ID, payload)
            .setIncludeDeviceName(true)
            .build()

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        // Each attempt gets its own callback instance. The active marker
        // (currentCallback) lets the AdvertiseCallback methods recognize
        // events that belong to a superseded attempt and ignore them.
        val cb = makeCallback()
        return try {
            // Order matters: claim isStarting + currentCallback *before* the
            // platform call so a callback that fires synchronously on the
            // same thread sees a consistent state and the success transition
            // lands on top.
            isStarting = true
            advertiser = leAdvertiser
            currentCallback = cb
            leAdvertiser.startAdvertising(settings, advData, scanResponse, cb)
            Log.i(TAG, "Advertising start requested")
            true
        } catch (e: SecurityException) {
            isStarting = false
            advertiser = null
            if (currentCallback === cb) currentCallback = null
            restoreAdapterName()
            Log.e(TAG, "Missing BLUETOOTH_ADVERTISE permission", e)
            false
        } catch (e: Exception) {
            isStarting = false
            advertiser = null
            if (currentCallback === cb) currentCallback = null
            restoreAdapterName()
            Log.e(TAG, "Error starting advertising", e)
            false
        }
    }

    /**
     * Stop LE advertising and restore the user's previous Bluetooth name.
     * Safe to call when not running.
     *
     * Returns true on a clean stop (or when nothing was running), false if
     * the platform threw — letting the MethodChannel caller surface the
     * failure to Dart instead of pretending everything went green.
     */
    fun stop(): Boolean {
        val leAdvertiser = advertiser
        val cb = currentCallback
        // Always clear local state, even if the underlying call throws or
        // there's nothing to stop — leaving stale flags would block a
        // subsequent start(). Clearing currentCallback first means any
        // late callback events for the just-stopped attempt see the
        // identity-mismatch guard and bail without mutating state.
        advertiser = null
        isAdvertising = false
        isStarting = false
        currentCallback = null

        var success = true
        if (leAdvertiser != null && cb != null) {
            try {
                leAdvertiser.stopAdvertising(cb)
                Log.i(TAG, "Advertising stopped")
            } catch (e: SecurityException) {
                success = false
                Log.e(TAG, "Missing Bluetooth permissions for stopAdvertising", e)
            } catch (e: Exception) {
                success = false
                Log.e(TAG, "Error stopping advertising", e)
            }
        }
        // Restore even if stopAdvertising threw — we don't want a stuck
        // SecurityException to permanently keep the user's phone renamed.
        restoreAdapterName()
        return success
    }

    private fun restoreAdapterName() {
        val saved = savedAdapterName ?: return
        val adapter = bluetoothAdapter ?: return
        try {
            adapter.setName(saved)
            // Only drop the rollback value once the OS confirmed it stuck.
            // If setName throws (e.g., BLUETOOTH_CONNECT revoked between
            // start and stop), keep savedAdapterName so a subsequent stop()
            // or onDestroy() can retry the restore — losing the original
            // here would leave the user's phone permanently renamed.
            savedAdapterName = null
        } catch (e: SecurityException) {
            Log.w(TAG, "Could not restore adapter name; will retry on next stop", e)
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
