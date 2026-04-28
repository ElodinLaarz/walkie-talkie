package com.elodin.walkie_talkie

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Manages audio routing for the walkie-talkie voice stream.
 * Routes mixed output to Bluetooth headsets, phone earpiece, or speaker
 * based on user preference and device availability.
 */
class AudioRoutingManager(private val ctx: Context) {
    companion object {
        private const val TAG = "AudioRoutingManager"
    }

    private val audioManager = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var deviceCallback: AudioDeviceCallback? = null
    private var onChangeListener: ((String) -> Unit)? = null
    private val handler = Handler(Looper.getMainLooper())

    /**
     * Set the audio output routing.
     * @param output One of "bluetooth", "earpiece", or "speaker"
     * @return true if routing was successfully configured, false otherwise
     */
    fun setOutput(output: String): Boolean {
        try {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

            when (output) {
                "bluetooth" -> {
                    // For LE Audio + classic A2DP/HSP headsets
                    val bt = audioManager.availableCommunicationDevices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                        it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                        it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                    }
                    if (bt != null) {
                        val success = audioManager.setCommunicationDevice(bt)
                        if (success) {
                            Log.i(TAG, "Routed audio to Bluetooth: ${bt.productName}")
                        } else {
                            Log.w(TAG, "Failed to route to Bluetooth device")
                        }
                        return success
                    } else {
                        Log.w(TAG, "No Bluetooth device available for audio routing")
                        return false
                    }
                }
                "earpiece" -> {
                    val ear = audioManager.availableCommunicationDevices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                    }
                    if (ear != null) {
                        val success = audioManager.setCommunicationDevice(ear)
                        if (success) {
                            Log.i(TAG, "Routed audio to earpiece")
                        } else {
                            Log.w(TAG, "Failed to route to earpiece")
                        }
                        return success
                    } else {
                        Log.w(TAG, "Earpiece not available")
                        return false
                    }
                }
                "speaker" -> {
                    val spk = audioManager.availableCommunicationDevices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                    }
                    if (spk != null) {
                        val success = audioManager.setCommunicationDevice(spk)
                        if (success) {
                            Log.i(TAG, "Routed audio to speaker")
                        } else {
                            Log.w(TAG, "Failed to route to speaker")
                        }
                        return success
                    } else {
                        Log.w(TAG, "Speaker not available")
                        return false
                    }
                }
                else -> {
                    Log.e(TAG, "Invalid output type: $output")
                    return false
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error setting audio output to $output", e)
            return false
        }
    }

    /**
     * Start auto-detection of audio device changes.
     * When a Bluetooth headset connects, automatically routes audio to it.
     * When it disconnects, calls the onChange callback to let the UI decide fallback.
     *
     * @param onChange Callback invoked with the detected output type when devices change
     */
    fun startAutoDetect(onChange: (String) -> Unit) {
        onChangeListener = onChange

        deviceCallback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                super.onAudioDevicesAdded(addedDevices)

                // Check if a Bluetooth device was added
                val btDevice = addedDevices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                }

                if (btDevice != null) {
                    Log.i(TAG, "Bluetooth device connected: ${btDevice.productName}")
                    // Auto-route to Bluetooth within 1s
                    handler.postDelayed({
                        if (setOutput("bluetooth")) {
                            onChange("bluetooth")
                        }
                    }, 100) // Small delay to ensure device is ready
                }
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                super.onAudioDevicesRemoved(removedDevices)

                // Check if a Bluetooth device was removed
                val btDevice = removedDevices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                }

                if (btDevice != null) {
                    Log.i(TAG, "Bluetooth device disconnected: ${btDevice.productName}")
                    // Notify UI to decide fallback (default to speaker)
                    onChange("speaker")
                }
            }
        }

        audioManager.registerAudioDeviceCallback(deviceCallback, handler)
        Log.i(TAG, "Auto-detect started for audio device changes")
    }

    /**
     * Stop auto-detection of audio device changes.
     */
    fun stopAutoDetect() {
        deviceCallback?.let {
            audioManager.unregisterAudioDeviceCallback(it)
            deviceCallback = null
            onChangeListener = null
            Log.i(TAG, "Auto-detect stopped")
        }
    }

    /**
     * Get the currently active audio output device type.
     * @return One of "bluetooth", "earpiece", "speaker", or "unknown"
     */
    fun getCurrentOutput(): String {
        val currentDevice = audioManager.communicationDevice
        if (currentDevice == null) {
            Log.w(TAG, "No communication device set")
            return "unknown"
        }

        return when (currentDevice.type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
            else -> "unknown"
        }
    }

    /**
     * Clean up resources.
     */
    fun cleanup() {
        stopAutoDetect()
    }
}
