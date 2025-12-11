package com.elodin.walkie_talkie

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.util.Log

class SystemAudioCaptureManager(private val mediaProjection: MediaProjection) {
    companion object {
        private const val TAG = "SystemAudioCapture"
        private const val SAMPLE_RATE = 48000
    }

    private var audioRecord: AudioRecord? = null
    private var isCapturing = false
    private var captureThread: Thread? = null

    @SuppressLint("MissingPermission")
    fun startCapture(onAudioData: (ShortArray) -> Unit) {
        val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val audioFormat = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()

        val minBufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )

        audioRecord = AudioRecord.Builder()
            .setAudioPlaybackCaptureConfig(config)
            .setAudioFormat(audioFormat)
            .setBufferSizeInBytes(minBufferSize * 2)
            .build()

        audioRecord?.startRecording()
        isCapturing = true

        captureThread = Thread {
            val buffer = ShortArray(1024)
            while (isCapturing) {
                val readCount = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                if (readCount > 0) {
                    onAudioData(buffer.copyOfRange(0, readCount))
                }
            }
        }
        captureThread?.start()
    }

    fun stopCapture() {
        isCapturing = false
        captureThread?.join()
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
    }
}
