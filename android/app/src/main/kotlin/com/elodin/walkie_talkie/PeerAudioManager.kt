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
    fun onVoiceFrameReceived(macAddress: String, opusData: ByteArray, seq: Long) {
        if (seq !in 0..0xFFFF_FFFFL) {
            Log.w(TAG, "Dropping voice frame from $macAddress: seq=$seq is not a valid uint32")
            return
        }
        nativeOnVoiceFrameReceived(macAddress, opusData, seq)
    }

    fun clear() {
        nativeClear()
    }

    // Called from native code (JNI callback)
    @Suppress("unused")
    private fun onMixedAudioReady(macAddress: String, opusData: ByteArray, seq: Int) {
        callback?.onMixedAudioReady(macAddress, opusData, seq)
    }

    // Native methods
    private external fun nativeInit()
    private external fun nativeRegisterPeer(macAddress: String): Int
    private external fun nativeUnregisterPeer(macAddress: String)
    private external fun nativeStartMixerThread(): Boolean
    private external fun nativeStopMixerThread()
    private external fun nativeSetCallback(callback: Any)
    private external fun nativeClear()
    private external fun nativeOnVoiceFrameReceived(macAddress: String, opusData: ByteArray, seq: Long)
}
