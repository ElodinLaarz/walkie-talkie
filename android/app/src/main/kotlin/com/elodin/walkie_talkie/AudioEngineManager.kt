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
     * Gate whether captured mic frames are sent to the mixer / transport.
     * Keeps streams warm so unmuting is instant.
     * @param muted true to silence local mic in the audio path
     * @return true on success
     */
    fun setMuted(muted: Boolean): Boolean {
        Log.i(TAG, "Setting mute state: $muted")
        return nativeSetMuted(muted)
    }

    /**
     * Pause both Oboe streams without tearing them down. Used on
     * AUDIOFOCUS_LOSS_TRANSIENT (e.g. an incoming call) so the OS can
     * reclaim the audio path without the engine fighting it. Counterpart
     * to [resumeStreams]; safe to call when the engine isn't started
     * (resolves to a no-op flag flip).
     *
     * @return true if pause succeeded for all live streams (or no engine
     *   was running); false if Oboe rejected a requestPause call.
     */
    fun pauseStreams(): Boolean {
        Log.i(TAG, "Pausing audio streams (audio focus loss)")
        return nativePauseStreams()
    }

    /**
     * Resume the streams paused by [pauseStreams]. Called on AUDIOFOCUS_GAIN.
     *
     * Note: does **not** restore the ducking volume. Pause and ducking are
     * orthogonal at the native layer — callers that want to clear ducking
     * (e.g. on focus gain after a transient duck) must explicitly call
     * [setDuckingVolume] with [AudioFocusManager.FULL_VOLUME].
     *
     * @return true if resume succeeded for all live streams (or no engine
     *   was running); false if Oboe rejected a requestStart call.
     */
    fun resumeStreams(): Boolean {
        Log.i(TAG, "Resuming audio streams (audio focus gain)")
        return nativeResumeStreams()
    }

    /**
     * Apply an output volume multiplier in [0.0, 1.0]. Driven by
     * AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK so a media app's nav prompt
     * doesn't drown out walkie audio. Values outside the range are
     * clamped on the native side.
     */
    fun setDuckingVolume(volume: Float) {
        Log.i(TAG, "Setting ducking volume: $volume")
        nativeSetDuckingVolume(volume)
    }

    /**
     * Enables a single-device loopback validation path. When enabled, the
     * native audio callback routes local mic PCM into a synthetic mixer peer
     * before writing the mixed result to the playback stream. Production voice
     * rooms keep this disabled so users do not hear their own microphone.
     */
    fun setLoopbackTestMode(enabled: Boolean): Boolean {
        Log.i(TAG, "Setting loopback test mode: $enabled")
        return nativeSetLoopbackTestMode(enabled)
    }

    // Native methods
    private external fun nativeStart(): Boolean
    private external fun nativeStop()
    private external fun nativeSetMuted(muted: Boolean): Boolean
    private external fun nativePauseStreams(): Boolean
    private external fun nativeResumeStreams(): Boolean
    private external fun nativeSetDuckingVolume(volume: Float)
    private external fun nativeSetLoopbackTestMode(enabled: Boolean): Boolean
}
