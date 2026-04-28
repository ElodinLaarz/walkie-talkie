package com.elodin.walkie_talkie

import android.util.Log

class AudioEngineManager {
    companion object {
        private const val TAG = "AudioEngineManager"
        init { System.loadLibrary("walkie_talkie_audio") }
    }

    private var talkingCallback: ((Boolean) -> Unit)? = null

    /**
     * Start the audio engine.
     * [onTalkingChanged] is registered as the VAD callback only on success —
     * a failed start clears any previous callback so stale lambdas are not held.
     */
    fun start(onTalkingChanged: ((Boolean) -> Unit)? = null): Boolean {
        Log.i(TAG, "Starting audio engine")
        val started = nativeStart()
        talkingCallback = if (started) onTalkingChanged else null
        return started
    }

    fun stop() {
        Log.i(TAG, "Stopping audio engine")
        talkingCallback = null
        nativeStop()
    }

    fun setMuted(muted: Boolean): Boolean {
        Log.i(TAG, "Setting mute state: $muted")
        return nativeSetMuted(muted)
    }

    fun getAudioData(numFrames: Int): ShortArray? = nativeGetAudioData(numFrames)

    fun playAudioData(audioData: ShortArray) = nativePlayAudioData(audioData)

    /** Called from the JNI layer (audio thread) when local voice-activity state changes. */
    fun onTalkingChanged(talking: Boolean) {
        talkingCallback?.invoke(talking)
    }

    private external fun nativeStart(): Boolean
    private external fun nativeStop()
    private external fun nativeGetAudioData(numFrames: Int): ShortArray?
    private external fun nativePlayAudioData(audioData: ShortArray)
    private external fun nativeSetMuted(muted: Boolean): Boolean
}