package com.elodin.walkie_talkie

import android.util.Log

/**
 * Manages the audio mixer for mix-minus routing.
 * Each device hears all other devices except themselves.
 */
class AudioMixerManager {
    companion object {
        private const val TAG = "AudioMixerManager"
        
        init {
            System.loadLibrary("walkie_talkie_audio")
        }
    }
    
    init {
        nativeInit()
    }
    
    /**
     * Add a device to the mixer.
     * @param deviceId Unique identifier for the device
     * @return true if added successfully, false if max devices reached
     */
    fun addDevice(deviceId: Int): Boolean {
        Log.i(TAG, "Adding device: $deviceId")
        return nativeAddDevice(deviceId)
    }
    
    /**
     * Remove a device from the mixer.
     * @param deviceId Unique identifier for the device
     */
    fun removeDevice(deviceId: Int) {
        Log.i(TAG, "Removing device: $deviceId")
        nativeRemoveDevice(deviceId)
    }
    
    /**
     * Update audio data for a specific device.
     * @param deviceId Device identifier
     * @param audioData 16-bit PCM audio samples from this device
     */
    fun updateDeviceAudio(deviceId: Int, audioData: ShortArray) {
        nativeUpdateDeviceAudio(deviceId, audioData)
    }
    
    /**
     * Get mixed audio for a specific device (all others except this device).
     * @param deviceId Device identifier
     * @param numFrames Number of audio frames
     * @return Mixed audio data
     */
    fun getMixedAudio(deviceId: Int, numFrames: Int): ShortArray? {
        return nativeGetMixedAudio(deviceId, numFrames)
    }
    
    /**
     * Clear all devices from the mixer.
     */
    fun clear() {
        Log.i(TAG, "Clearing mixer")
        nativeClear()
    }
    
    // Native methods
    private external fun nativeInit()
    private external fun nativeAddDevice(deviceId: Int): Boolean
    private external fun nativeRemoveDevice(deviceId: Int)
    private external fun nativeUpdateDeviceAudio(deviceId: Int, audioData: ShortArray)
    private external fun nativeGetMixedAudio(deviceId: Int, numFrames: Int): ShortArray?
    private external fun nativeClear()
}
