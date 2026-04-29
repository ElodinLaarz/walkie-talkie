package com.elodin.walkie_talkie

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.util.Log

/**
 * Requests Android Audio Focus for the walkie-talkie voice stream so the
 * Oboe engine doesn't fight phone calls or media apps for the audio path.
 *
 * Lifecycle: one focus request per service start. The returned focus-change
 * callback is what the service uses to drive [AudioEngineManager.pauseStreams]
 * / [AudioEngineManager.resumeStreams] / [AudioEngineManager.setDuckingVolume].
 *
 * Mapping of focus-change codes to action (handled by the caller):
 *   - AUDIOFOCUS_LOSS_TRANSIENT (incoming call): pause both streams.
 *   - AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK (Spotify nav prompt): drop volume.
 *   - AUDIOFOCUS_GAIN: resume + clear ducking.
 *   - AUDIOFOCUS_LOSS (long-lived): pause; per #55's acceptance criteria we
 *     don't auto-leave the room (the user can come back and re-tune).
 */
class AudioFocusManager(ctx: Context) {
    companion object {
        private const val TAG = "AudioFocusManager"

        /** Output multiplier when ducking. -10 dB matches OEM media defaults. */
        const val DUCK_VOLUME = 0.3f

        /** Full volume — pass to setDuckingVolume to clear ducking. */
        const val FULL_VOLUME = 1.0f
    }

    private val audioManager =
        ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var request: AudioFocusRequest? = null

    /**
     * Request audio focus. The same listener stays attached to the request
     * for its lifetime; calling [requestFocus] a second time without an
     * intervening [abandon] is a no-op and returns true.
     *
     * @param onFocusChange Invoked with the AudioManager focus-change codes
     *   (AUDIOFOCUS_GAIN, AUDIOFOCUS_LOSS, AUDIOFOCUS_LOSS_TRANSIENT,
     *   AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK). Always invoked on the main
     *   thread (AudioManager guarantees this for the listener variant we use).
     * @return true if focus was granted (or accepted as delayed grant),
     *   false if the system denied the request.
     */
    fun requestFocus(onFocusChange: (Int) -> Unit): Boolean {
        if (request != null) {
            Log.w(TAG, "Audio focus already held; ignoring duplicate request")
            return true
        }

        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attrs)
            .setAcceptsDelayedFocusGain(true)
            .setOnAudioFocusChangeListener { focusChange ->
                Log.i(TAG, "Audio focus change: $focusChange")
                onFocusChange(focusChange)
            }
            .build()

        return when (val result = audioManager.requestAudioFocus(req)) {
            AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> {
                Log.i(TAG, "Audio focus granted")
                request = req
                true
            }
            AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> {
                // A higher-priority stream (e.g. an active call) is holding
                // focus; the system will deliver AUDIOFOCUS_GAIN to the
                // listener once it's free. Hang on to the request so abandon
                // can release the pending grant.
                Log.i(TAG, "Audio focus delayed (will be granted later)")
                request = req
                true
            }
            else -> {
                Log.w(TAG, "Audio focus denied: result=$result")
                false
            }
        }
    }

    /**
     * Release any focus held by [requestFocus]. Safe to call when no focus
     * is held — resolves to a no-op.
     */
    fun abandon() {
        val req = request ?: return
        val result = audioManager.abandonAudioFocusRequest(req)
        Log.i(TAG, "Audio focus abandoned: result=$result")
        request = null
    }
}
