package com.elodin.walkie_talkie

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class GattConstantsTest {

    @Test
    fun serviceUuidMatchesSpec() {
        assertEquals(
            UUID.fromString("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e8e"),
            GattConstants.SERVICE_UUID
        )
    }

    @Test
    fun requestCharUuidMatchesSpec() {
        assertEquals(
            UUID.fromString("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e01"),
            GattConstants.REQUEST_CHAR_UUID
        )
    }

    @Test
    fun responseCharUuidMatchesSpec() {
        assertEquals(
            UUID.fromString("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e02"),
            GattConstants.RESPONSE_CHAR_UUID
        )
    }

    @Test
    fun cccdUuidMatchesStandardSpec() {
        assertEquals(
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"),
            GattConstants.CCCD_UUID
        )
    }

    @Test
    fun targetMtuIs247() {
        assertEquals(247, GattConstants.TARGET_ATT_MTU)
    }

    @Test
    fun voiceMtuIs128() {
        assertEquals(128, GattConstants.VOICE_MTU)
    }

    @Test
    fun authorizationErrorsContainsInsufficientAuthorizationCode() {
        assertTrue("GATT_INSUFFICIENT_AUTHORIZATION(8) missing", 8 in GattConstants.AUTHORIZATION_ERRORS)
    }

    @Test
    fun authorizationErrorsContainsInsufficientAuthenticationCode() {
        assertTrue("GATT_INSUFFICIENT_AUTHENTICATION(5) missing", 5 in GattConstants.AUTHORIZATION_ERRORS)
    }

    @Test
    fun authorizationErrorsContainsInsufficientEncryptionCode() {
        assertTrue("GATT_INSUFFICIENT_ENCRYPTION(15) missing", 15 in GattConstants.AUTHORIZATION_ERRORS)
    }

    @Test
    fun authorizationErrorsExcludesTransientGattErrors() {
        // 133 / 147 are retried, not treated as auth denials
        assertFalse("133 should not be an auth error", 133 in GattConstants.AUTHORIZATION_ERRORS)
        assertFalse("147 should not be an auth error", 147 in GattConstants.AUTHORIZATION_ERRORS)
        assertFalse("0 should not be an auth error", 0 in GattConstants.AUTHORIZATION_ERRORS)
    }
}
