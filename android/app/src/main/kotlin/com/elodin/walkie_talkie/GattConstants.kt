package com.elodin.walkie_talkie

import java.util.UUID

/**
 * Single source of truth for the wire-level identifiers and MTU constants
 * shared between the GATT client (guest), GATT server (host), the L2CAP
 * voice transport, and any future native module that needs to recognize the
 * walkie-talkie service.
 *
 * The values must stay byte-identical to:
 *  - `lib/protocol/discovery.dart::kWalkieTalkieServiceUuid` (Dart side, used
 *    for advertising filters), and
 *  - `docs/protocol.md § GATT service` (the spec callers verify against).
 *
 * Per issue #107 — anything that wants a UUID, a target ATT MTU, or the
 * voice-plane MTU must read it from here. Previously these were duplicated
 * across `GattClientManager`, `GattServerManager`, and `L2capVoiceTransport`.
 */
object GattConstants {
    /** 128-bit primary service UUID for the walkie-talkie GATT service. */
    @JvmField
    val SERVICE_UUID: UUID =
        UUID.fromString("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e8e")

    /** Write / write-no-response characteristic — guests post requests here. */
    @JvmField
    val REQUEST_CHAR_UUID: UUID =
        UUID.fromString("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e01")

    /** Notify characteristic — hosts push responses + roster updates here. */
    @JvmField
    val RESPONSE_CHAR_UUID: UUID =
        UUID.fromString("8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e02")

    /** Standard Client Characteristic Configuration Descriptor (CCCD). */
    @JvmField
    val CCCD_UUID: UUID =
        UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    /**
     * ATT MTU the guest requests after connect. The peer may grant less; the
     * actual negotiated MTU is cached per-device by `GattServerManager`
     * (issue #45).
     */
    const val TARGET_ATT_MTU: Int = 247

    /**
     * L2CAP CoC voice plane: maximum VoiceFrame payload size. Each frame on
     * the wire is preceded by a 2-byte big-endian length prefix (see
     * `L2capVoiceTransport`'s class doc + `docs/protocol.md § Voice frame
     * format`), so the on-the-wire L2CAP write is up to `VOICE_MTU + 2`
     * bytes; the SDU MTU must be sized accordingly. Mirrors `kVoiceMtu` in
     * `lib/protocol/voice_frame.dart`.
     */
    const val VOICE_MTU: Int = 128
}
