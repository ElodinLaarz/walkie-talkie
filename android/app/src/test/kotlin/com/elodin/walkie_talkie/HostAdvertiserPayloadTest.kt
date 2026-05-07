package com.elodin.walkie_talkie

import android.content.Context
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.mock
import java.util.UUID

/**
 * Unit tests for the manufacturer payload encoding in HostAdvertiser.
 *
 * The payload layout (docs/protocol.md § "Bluetooth LE advertising"):
 *   [0]    protocol version (0x01 for v1)
 *   [1]    role (0x01 = host)
 *   [2..9] low 8 bytes of sessionUuid (leastSignificantBits, big-endian)
 *   [10..15] reserved zeros
 */
class HostAdvertiserPayloadTest {

    private lateinit var advertiser: HostAdvertiser

    @Before
    fun setup() {
        // Context is only used in start()/stop() — the advertiser stores it but
        // buildManufacturerPayload is a pure algorithm that touches no Android APIs.
        advertiser = HostAdvertiser(mock(Context::class.java))
    }

    @Test
    fun payloadLengthIs16() {
        val payload = advertiser.buildManufacturerPayload("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e8e")
        assertEquals(16, payload.size)
    }

    @Test
    fun payloadProtocolVersionIsV1() {
        val payload = advertiser.buildManufacturerPayload("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e8e")
        assertEquals(0x01.toByte(), payload[0])
    }

    @Test
    fun payloadRoleIsHost() {
        val payload = advertiser.buildManufacturerPayload("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e8e")
        assertEquals(0x01.toByte(), payload[1])
    }

    @Test
    fun payloadEncodesUuidLsbBigEndian() {
        val uuidStr = "12345678-1234-1234-1234-abcdef012345"
        val uuid = UUID.fromString(uuidStr)
        val lsb = uuid.leastSignificantBits
        val payload = advertiser.buildManufacturerPayload(uuidStr)

        for (i in 0..7) {
            val expected = ((lsb ushr (56 - i * 8)) and 0xFFL).toByte()
            assertEquals("payload byte ${2 + i} mismatch", expected, payload[2 + i])
        }
    }

    @Test
    fun reservedBytesAreZero() {
        val payload = advertiser.buildManufacturerPayload("deadbeef-cafe-babe-1234-567890abcdef")
        for (i in 10..15) {
            assertEquals("reserved byte $i should be zero", 0.toByte(), payload[i])
        }
    }

    @Test
    fun roundTripLsbExtraction() {
        val uuidStr = "deadbeef-cafe-babe-1234-567890abcdef"
        val uuid = UUID.fromString(uuidStr)
        val payload = advertiser.buildManufacturerPayload(uuidStr)

        var extractedLsb = 0L
        for (i in 0..7) {
            extractedLsb = (extractedLsb shl 8) or (payload[2 + i].toLong() and 0xFFL)
        }
        assertEquals(uuid.leastSignificantBits, extractedLsb)
    }

    @Test
    fun differentUuidsProduceDifferentPayloads() {
        val p1 = advertiser.buildManufacturerPayload("00000000-0000-0000-0000-000000000001")
        val p2 = advertiser.buildManufacturerPayload("00000000-0000-0000-0000-000000000002")
        // At minimum the LSB byte should differ
        val differs = p1.indices.any { p1[it] != p2[it] }
        assertEquals(true, differs)
    }

    @Test
    fun invalidUuidThrows() {
        try {
            advertiser.buildManufacturerPayload("not-a-valid-uuid")
            fail("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun emptyUuidStringThrows() {
        try {
            advertiser.buildManufacturerPayload("")
            fail("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun allZeroUuidEncodesCorrectly() {
        val uuidStr = "00000000-0000-0000-0000-000000000000"
        val payload = advertiser.buildManufacturerPayload(uuidStr)
        assertEquals(0x01.toByte(), payload[0])
        assertEquals(0x01.toByte(), payload[1])
        assertArrayEquals(ByteArray(8), payload.copyOfRange(2, 10))
        assertArrayEquals(ByteArray(6), payload.copyOfRange(10, 16))
    }
}
