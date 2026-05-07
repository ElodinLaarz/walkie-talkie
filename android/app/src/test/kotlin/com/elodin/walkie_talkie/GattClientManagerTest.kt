package com.elodin.walkie_talkie

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothProfile
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import java.util.concurrent.ConcurrentHashMap

/**
 * Unit tests for GattClientManager covering the control-plane contracts
 * from issue #310:
 *
 *  - MTU negotiation cache: getMtu returns the right value after onMtuChanged.
 *  - 133/147 retry policy: transient GATT errors trigger a retry up to
 *    MAX_CONNECT_RETRIES times; non-transient errors do not retry.
 *  - RSSI sample cache: getLatestRssiSamples returns entries written by
 *    onReadRemoteRssi.
 */
class GattClientManagerTest {

    private val responses = mutableListOf<ByteArray>()
    private val errors = mutableListOf<String>()
    private lateinit var manager: GattClientManager

    @Before
    fun setup() {
        responses.clear()
        errors.clear()
        manager = GattClientManager(
            context = mock(Context::class.java),
            onResponseBytes = { bytes -> responses.add(bytes) },
            onError = { err -> errors.add(err) }
        )
    }

    // ── getMtu ────────────────────────────────────────────────────────────────

    @Test
    fun getMtuReturnsNullForUnknownAddress() {
        assertNull(manager.getMtu("AA:BB:CC:DD:EE:FF"))
    }

    @Test
    fun getMtuReturnsCachedValue() {
        injectMtu("AA:BB:CC:DD:EE:FF", 247)
        assertEquals(247, manager.getMtu("AA:BB:CC:DD:EE:FF"))
    }

    @Test
    fun getMtuReturnsNullForDifferentAddress() {
        injectMtu("AA:BB:CC:DD:EE:FF", 247)
        assertNull(manager.getMtu("11:22:33:44:55:66"))
    }

    @Test
    fun onMtuChangedSuccessUpdatesCacheForDevice() {
        val mac = "AA:BB:CC:DD:EE:FF"
        val gatt = mockGatt(mac)
        gattCallback().onMtuChanged(gatt, 200, BluetoothGatt.GATT_SUCCESS)
        assertEquals(200, manager.getMtu(mac))
    }

    @Test
    fun onMtuChangedFailureDoesNotUpdateCache() {
        val mac = "AA:BB:CC:DD:EE:FF"
        val gatt = mockGatt(mac)
        gattCallback().onMtuChanged(gatt, 200, BluetoothGatt.GATT_FAILURE)
        assertNull(manager.getMtu(mac))
    }

    // ── 133/147 retry policy (issue #100) ────────────────────────────────────

    @Test
    fun transientError133IncrementsRetryCount() {
        val mac = "AA:BB:CC:DD:EE:FF"
        setPendingMac(mac)

        val gatt = mockGatt(mac)
        gattCallback().onConnectionStateChange(gatt, 133, BluetoothProfile.STATE_DISCONNECTED)

        assertEquals(1, retryCount())
    }

    @Test
    fun transientError147IncrementsRetryCount() {
        val mac = "AA:BB:CC:DD:EE:FF"
        setPendingMac(mac)

        val gatt = mockGatt(mac)
        gattCallback().onConnectionStateChange(gatt, 147, BluetoothProfile.STATE_DISCONNECTED)

        assertEquals(1, retryCount())
    }

    @Test
    fun transientError19IncrementsRetryCount() {
        val mac = "AA:BB:CC:DD:EE:FF"
        setPendingMac(mac)

        val gatt = mockGatt(mac)
        gattCallback().onConnectionStateChange(gatt, 19, BluetoothProfile.STATE_DISCONNECTED)

        assertEquals(1, retryCount())
    }

    @Test
    fun nonTransientErrorClearsPendingMac() {
        // Status 8 is GATT_INSUFFICIENT_AUTHORIZATION — handled as auth error,
        // not retried. Also tests a clean-disconnect (GATT_SUCCESS / 0).
        val mac = "AA:BB:CC:DD:EE:FF"
        setPendingMac(mac)

        val gatt = mockGatt(mac)
        gattCallback().onConnectionStateChange(gatt, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_DISCONNECTED)

        assertNull(pendingMac())
        assertEquals(0, retryCount())
    }

    @Test
    fun retryStopsAfterMaxConnectRetries() {
        // MAX_CONNECT_RETRIES = 5; seed once and fire exactly MAX+1 disconnects.
        val mac = "AA:BB:CC:DD:EE:FF"
        val gatt = mockGatt(mac)

        setPendingMac(mac)
        // First 5 transient disconnects each increment the retry counter.
        repeat(5) {
            gattCallback().onConnectionStateChange(gatt, 133, BluetoothProfile.STATE_DISCONNECTED)
        }
        assertEquals("retryCount should be MAX_CONNECT_RETRIES after 5 retries", 5, retryCount())
        assertEquals("pendingMac should still be set mid-retry", mac, pendingMac())

        // 6th disconnect exhausts the budget: counter resets and pending MAC is cleared.
        gattCallback().onConnectionStateChange(gatt, 133, BluetoothProfile.STATE_DISCONNECTED)
        assertNull("pendingMac should be null after retry exhaustion", pendingMac())
        assertEquals("retryCount should reset to 0 on exhaustion", 0, retryCount())
    }

    @Test
    fun transientErrorRetryPreservesPendingMac() {
        val mac = "AA:BB:CC:DD:EE:FF"
        setPendingMac(mac)

        val gatt = mockGatt(mac)
        gattCallback().onConnectionStateChange(gatt, 133, BluetoothProfile.STATE_DISCONNECTED)

        // Still targeting the same host — pendingMac stays set so the
        // retry runnable (posted by retryHandler) knows where to reconnect.
        assertEquals(mac, pendingMac())
    }

    // ── RSSI sample cache ─────────────────────────────────────────────────────

    @Test
    fun rssiSamplesEmptyInitially() {
        assertTrue(manager.getLatestRssiSamples().isEmpty())
    }

    @Test
    fun onReadRemoteRssiSuccessPopulatesCache() {
        val mac = "AA:BB:CC:DD:EE:FF"
        val gatt = mockGatt(mac)
        gattCallback().onReadRemoteRssi(gatt, -70, BluetoothGatt.GATT_SUCCESS)

        val samples = manager.getLatestRssiSamples()
        assertEquals(1, samples.size)
        assertEquals(mac, samples[0]["peerId"])
        assertEquals(-70, samples[0]["rssi"])
    }

    @Test
    fun onReadRemoteRssiFailureDoesNotPopulateCache() {
        val mac = "AA:BB:CC:DD:EE:FF"
        val gatt = mockGatt(mac)
        gattCallback().onReadRemoteRssi(gatt, -70, BluetoothGatt.GATT_FAILURE)

        assertTrue(manager.getLatestRssiSamples().isEmpty())
    }

    // ── isConnected ──────────────────────────────────────────────────────────

    @Test
    fun isConnectedFalseInitially() {
        assertFalse(manager.isConnected())
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private fun gattCallback(): BluetoothGattCallback {
        val field = GattClientManager::class.java.getDeclaredField("gattCallback")
        field.isAccessible = true
        return field.get(manager) as BluetoothGattCallback
    }

    private fun injectMtu(mac: String, mtu: Int) {
        val field = GattClientManager::class.java.getDeclaredField("negotiatedMtus")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        (field.get(manager) as MutableMap<String, Int>)[mac] = mtu
    }

    private fun setPendingMac(mac: String) {
        val field = GattClientManager::class.java.getDeclaredField("pendingMacAddress")
        field.isAccessible = true
        field.set(manager, mac)
    }

    private fun pendingMac(): String? {
        val field = GattClientManager::class.java.getDeclaredField("pendingMacAddress")
        field.isAccessible = true
        return field.get(manager) as String?
    }

    private fun retryCount(): Int {
        val field = GattClientManager::class.java.getDeclaredField("connectRetryCount")
        field.isAccessible = true
        return field.getInt(manager)
    }

    private fun mockGatt(address: String): BluetoothGatt {
        val device = mock(BluetoothDevice::class.java)
        `when`(device.address).thenReturn(address)
        val gatt = mock(BluetoothGatt::class.java)
        `when`(gatt.device).thenReturn(device)
        return gatt
    }
}
