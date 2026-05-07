package com.elodin.walkie_talkie

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothProfile
import android.content.Context
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import java.util.concurrent.ConcurrentHashMap

/**
 * Unit tests for GattServerManager covering the control-plane contracts
 * from issue #310:
 *
 *  - MTU negotiation cache: getMtu returns the right value after onMtuChanged.
 *  - REQUEST characteristic writes invoke onBytesReceived (admit path).
 *  - Writes to unknown characteristics are silently ignored (deny path).
 */
class GattServerManagerTest {

    private val receivedBytes = mutableListOf<Pair<String, ByteArray>>()
    private val errors = mutableListOf<String>()
    private lateinit var manager: GattServerManager

    @Before
    fun setup() {
        receivedBytes.clear()
        errors.clear()
        manager = GattServerManager(
            context = mock(Context::class.java),
            onBytesReceived = { addr, bytes -> receivedBytes.add(addr to bytes) },
            onError = { err -> errors.add(err) }
        )
    }

    // ── getMtu ────────────────────────────────────────────────────────────────

    @Test
    fun getMtuReturnsNullForUnknownAddress() {
        assertNull(manager.getMtu("AA:BB:CC:DD:EE:FF"))
    }

    @Test
    fun getMtuReturnsCachedValueAfterOnMtuChanged() {
        val mac = "AA:BB:CC:DD:EE:FF"
        injectMtu(mac, 200)
        assertEquals(200, manager.getMtu(mac))
    }

    @Test
    fun getMtuReturnsNullForDifferentAddress() {
        injectMtu("AA:BB:CC:DD:EE:FF", 200)
        assertNull(manager.getMtu("11:22:33:44:55:66"))
    }

    @Test
    fun onMtuChangedViaCallbackUpdatesMtuCache() {
        val mac = "AA:BB:CC:DD:EE:FF"
        val device = mockDevice(mac)
        gattCallback().onMtuChanged(device, 247)
        assertEquals(247, manager.getMtu(mac))
    }

    @Test
    fun latestMtuValueOverwritesPreviousEntry() {
        val mac = "AA:BB:CC:DD:EE:FF"
        injectMtu(mac, 100)
        injectMtu(mac, 247)
        assertEquals(247, manager.getMtu(mac))
    }

    // ── onCharacteristicWriteRequest — admit (REQUEST char) ──────────────────

    @Test
    fun requestCharWriteDeliversBytesToCallback() {
        val mac = "AA:BB:CC:DD:EE:FF"
        val payload = byteArrayOf(1, 2, 3, 4)
        val device = mockDevice(mac)
        val char = mockChar(GattConstants.REQUEST_CHAR_UUID)

        // Java method — positional args required (device, requestId, characteristic,
        // preparedWrite, responseNeeded, offset, value)
        gattCallback().onCharacteristicWriteRequest(device, 1, char, false, false, 0, payload)

        assertEquals(1, receivedBytes.size)
        assertEquals(mac, receivedBytes[0].first)
        assertArrayEquals(payload, receivedBytes[0].second)
    }

    @Test
    fun requestCharWriteWithEmptyValueDoesNotCallCallback() {
        val device = mockDevice("AA:BB:CC:DD:EE:FF")
        val char = mockChar(GattConstants.REQUEST_CHAR_UUID)

        gattCallback().onCharacteristicWriteRequest(device, 1, char, false, false, 0, byteArrayOf())

        assertEquals(0, receivedBytes.size)
    }

    @Test
    fun requestCharWriteWithNullValueDoesNotCallCallback() {
        val device = mockDevice("AA:BB:CC:DD:EE:FF")
        val char = mockChar(GattConstants.REQUEST_CHAR_UUID)

        gattCallback().onCharacteristicWriteRequest(device, 1, char, false, false, 0, null)

        assertEquals(0, receivedBytes.size)
    }

    // ── onCharacteristicWriteRequest — deny (unknown char) ───────────────────

    @Test
    fun writeToUnknownCharacteristicDoesNotCallBytesReceivedCallback() {
        val device = mockDevice("AA:BB:CC:DD:EE:FF")
        val unknownChar = mockChar(GattConstants.RESPONSE_CHAR_UUID) // not REQUEST

        gattCallback().onCharacteristicWriteRequest(device, 2, unknownChar, false, false, 0, byteArrayOf(0x42))

        assertEquals(0, receivedBytes.size)
        assertEquals(0, errors.size)
    }

    // ── getConnectedAddresses ─────────────────────────────────────────────────

    @Test
    fun getConnectedAddressesEmptyInitially() {
        assertEquals(emptyList<String>(), manager.getConnectedAddresses())
    }

    @Test
    fun connectedDeviceAppearsAfterStateConnectedCallback() {
        val mac = "AA:BB:CC:DD:EE:FF"
        val device = mockDevice(mac)
        gattCallback().onConnectionStateChange(device, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
        assertEquals(listOf(mac), manager.getConnectedAddresses())
    }

    @Test
    fun disconnectedDeviceRemovedFromConnectedSet() {
        val mac = "AA:BB:CC:DD:EE:FF"
        val device = mockDevice(mac)
        gattCallback().onConnectionStateChange(device, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_CONNECTED)
        gattCallback().onConnectionStateChange(device, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_DISCONNECTED)
        assertEquals(emptyList<String>(), manager.getConnectedAddresses())
    }

    @Test
    fun mtuRemovedOnDisconnect() {
        val mac = "AA:BB:CC:DD:EE:FF"
        val device = mockDevice(mac)
        injectMtu(mac, 247)
        gattCallback().onConnectionStateChange(device, BluetoothGatt.GATT_SUCCESS, BluetoothProfile.STATE_DISCONNECTED)
        assertNull(manager.getMtu(mac))
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private fun gattCallback(): BluetoothGattServerCallback {
        val field = GattServerManager::class.java.getDeclaredField("gattCallback")
        field.isAccessible = true
        return field.get(manager) as BluetoothGattServerCallback
    }

    private fun injectMtu(mac: String, mtu: Int) {
        val field = GattServerManager::class.java.getDeclaredField("negotiatedMtus")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        (field.get(manager) as ConcurrentHashMap<String, Int>)[mac] = mtu
    }

    private fun mockDevice(address: String): BluetoothDevice {
        val d = mock(BluetoothDevice::class.java)
        `when`(d.address).thenReturn(address)
        return d
    }

    private fun mockChar(uuid: java.util.UUID): BluetoothGattCharacteristic {
        val c = mock(BluetoothGattCharacteristic::class.java)
        `when`(c.uuid).thenReturn(uuid)
        return c
    }
}
