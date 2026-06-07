package com.elodin.walkie_talkie

import android.util.Log

class PeerAudioManager {
    companion object {
        private const val TAG = "PeerAudioManager"

        init {
            System.loadLibrary("walkie_talkie_audio")
        }
    }

    private var callback: AudioCallback? = null

    interface AudioCallback {
        fun onMixedAudioReady(macAddress: String, opusData: ByteArray, seq: Int)
        fun onTalkingPeersChanged(peers: Set<String>)
    }

    fun init() {
        nativeInit()
        Log.i(TAG, "PeerAudioManager initialized")
    }

    fun registerPeer(macAddress: String): Int {
        val deviceId = nativeRegisterPeer(macAddress)
        Log.i(TAG, "Registered peer $macAddress with device ID $deviceId")
        return deviceId
    }

    fun unregisterPeer(macAddress: String) {
        nativeUnregisterPeer(macAddress)
        Log.i(TAG, "Unregistered peer $macAddress")
    }

    fun startMixerThread(): Boolean {
        val result = nativeStartMixerThread()
        Log.i(TAG, "Mixer thread start: $result")
        return result
    }

    fun stopMixerThread() {
        nativeStopMixerThread()
        Log.i(TAG, "Mixer thread stopped")
    }

    fun setCallback(callback: AudioCallback) {
        this.callback = callback
        nativeSetCallback(this)
    }

    /**
     * Hand a peer-arrived Opus frame to the native mixer along with its
     * per-link [seq] from the VoiceFrame header. Native uses [seq] to detect
     * a stuck or wildly-skipping producer (issue #49) and mute that peer's
     * stream until a frame within the protocol's threshold of the last
     * accepted seq arrives.
     *
     * [seq] is the protocol's uint32; passed as a [Long] so the unsigned
     * value survives the JNI hop without sign extension. We range-check it
     * here so a malformed VoiceFrame parse can't sneak a sign-extended
     * negative through to native, where it would silently truncate to a
     * different valid uint32 and either spuriously poison or recover the peer.
     * Out-of-range values are dropped (logged + return) rather than thrown:
     * this is an over-the-wire input boundary, and one bad packet must not
     * crash the foreground service.
     */
    fun onVoiceFrameReceived(
        macAddress: String,
        opusData: ByteArray,
        seq: Long,
        senderTsMs: Long,
    ) {
        if (seq !in 0..0xFFFF_FFFFL) {
            Log.w(TAG, "Dropping voice frame from $macAddress: seq=$seq is not a valid uint32")
            return
        }
        // senderTsMs is the VoiceFrame header's low-32 sender encode time; it is
        // already masked to a uint32 on the wire, but range-check defensively so
        // a malformed parse can't sign-extend a negative into native.
        if (senderTsMs !in 0..0xFFFF_FFFFL) {
            Log.w(TAG, "Dropping voice frame from $macAddress: senderTsMs=$senderTsMs out of range")
            return
        }
        nativeOnVoiceFrameReceived(macAddress, opusData, seq, senderTsMs)
    }

    fun clear() {
        nativeClear()
    }

    /**
     * Per-peer link telemetry snapshot — used by the host to drive dynamic
     * bitrate and by the UI to expose link health. Mirrors the C++
     * PeerAudioManager::LinkTelemetry struct (peer_audio_manager.h).
     *
     * `underrunCount` and `lateFrameCount` are lifetime totals; subtract
     * snapshots to get a rate. `currentDepthFrames` vs `targetDepthFrames`
     * tells you whether the jitter buffer is comfortably ahead of playout
     * or running on fumes — a sustained gap is the canonical "this link is
     * struggling" signal.
     */
    data class LinkTelemetry(
        val underrunCount: Int,
        val lateFrameCount: Int,
        val targetDepthFrames: Int,
        val currentDepthFrames: Int,
        val currentBitrateBps: Int,
        // True network loss (seq-gap). Drives bitrate adaptation; lateFrameCount
        // is kept for observability only.
        val lostFrameCount: Int,
        // End-to-end staleness telemetry for the debug dashboard.
        // currentLagMs: latest estimated staleness (ms above best recent transit).
        // staleDropCount: lifetime frames dropped on arrival as too stale.
        // recvCount: lifetime frames accepted into the jitter buffer.
        // lastSeq: most recently accepted seq (live head-of-stream).
        val currentLagMs: Int,
        val staleDropCount: Int,
        val recvCount: Int,
        val lastSeq: Int,
    )

    /**
     * Adjust this peer's outbound encoder bitrate. The native side clamps to
     * the {Low, Mid, High} range from audio_config.h. Returns the actual
     * bitrate applied (after clamping), or -1 if the peer isn't registered.
     *
     * Intended caller: a future LinkQuality reporter that polls
     * [getTelemetry] and steps bitrate down on sustained loss / underruns,
     * back up on a clean window. Today no automated caller exists; this is
     * scaffolding so the BLE control plane has a target API to wire to.
     */
    fun setPeerBitrate(macAddress: String, bps: Int): Int {
        val applied = nativeSetPeerBitrate(macAddress, bps)
        if (applied < 0) {
            Log.w(TAG, "setPeerBitrate($macAddress, $bps) failed: peer not registered")
        }
        return applied
    }

    fun setPeerVolume(macAddress: String, volume: Float) {
        nativeSetPeerVolume(macAddress, volume)
    }

    fun setPeerMuted(macAddress: String, muted: Boolean) {
        nativeSetPeerMuted(macAddress, muted)
    }

    /** Returns null if the peer isn't registered. */
    fun getTelemetry(macAddress: String): LinkTelemetry? {
        val raw = nativeGetTelemetry(macAddress) ?: return null
        if (raw.size != 10) {
            Log.w(TAG, "getTelemetry returned unexpected array size ${raw.size}")
            return null
        }
        return LinkTelemetry(
            underrunCount = raw[0],
            lateFrameCount = raw[1],
            targetDepthFrames = raw[2],
            currentDepthFrames = raw[3],
            currentBitrateBps = raw[4],
            lostFrameCount = raw[5],
            currentLagMs = raw[6],
            staleDropCount = raw[7],
            recvCount = raw[8],
            lastSeq = raw[9],
        )
    }

    // Called from native code (JNI callback)
    @Suppress("unused")
    private fun onMixedAudioReady(macAddress: String, opusData: ByteArray, seq: Int) {
        callback?.onMixedAudioReady(macAddress, opusData, seq)
    }

    // Called from native code (JNI callback) when any peer's VAD state changes.
    @Suppress("unused")
    private fun onTalkingPeersChanged(peers: Array<String>) {
        callback?.onTalkingPeersChanged(peers.toSet())
    }

    // Native methods
    private external fun nativeInit()
    private external fun nativeRegisterPeer(macAddress: String): Int
    private external fun nativeUnregisterPeer(macAddress: String)
    private external fun nativeStartMixerThread(): Boolean
    private external fun nativeStopMixerThread()
    private external fun nativeSetCallback(callback: Any)
    private external fun nativeClear()
    private external fun nativeOnVoiceFrameReceived(macAddress: String, opusData: ByteArray, seq: Long, senderTsMs: Long)
    private external fun nativeSetPeerBitrate(macAddress: String, bps: Int): Int
    private external fun nativeGetTelemetry(macAddress: String): IntArray?
    private external fun nativeSetPeerVolume(macAddress: String, volume: Float)
    private external fun nativeSetPeerMuted(macAddress: String, muted: Boolean)
}
