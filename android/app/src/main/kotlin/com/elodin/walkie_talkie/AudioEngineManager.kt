package com.elodin.walkie_talkie

import android.util.Log

/**
 * Manages the native audio engine (Oboe-based).
 * Handles low-latency audio capture and playback.
 */
class AudioEngineManager {
    companion object {
        private const val TAG = "AudioEngineManager"
        
        init {
            System.loadLibrary("walkie_talkie_audio")
        }
    }
    
    /**
     * Start the audio engine.
     * @return true if started successfully, false otherwise
     */
    fun start(): Boolean {
        Log.i(TAG, "Starting audio engine")
        return nativeStart()
    }
    
    /**
     * Stop the audio engine.
     */
    fun stop() {
        Log.i(TAG, "Stopping audio engine")
        nativeStop()
    }
    
    /**
     * Get captured audio data from the microphone.
     * @param numFrames Number of audio frames to retrieve
     * @return Audio data as 16-bit PCM samples
     */
    fun getAudioData(numFrames: Int): ShortArray? {
        return nativeGetAudioData(numFrames)
    }
    
    /**
     * Play received audio data through the speaker.
     * @param audioData 16-bit PCM audio samples
     */
    fun playAudioData(audioData: ShortArray) {
        nativePlayAudioData(audioData)
    }
    
    // Native methods
    private external fun nativeStart(): Boolean
    private external fun nativeStop()
    private external fun nativeGetAudioData(numFrames: Int): ShortArray?
    private external fun nativePlayAudioData(audioData: ShortArray)
}
