package com.meshchat.meshchat_mobile

import androidx.annotation.Keep
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

/** Runs only on WebRTC's capture processing thread, never through Dart PCM messages. */
@Keep
class MeshNoiseProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    private var state = create()
    private var channels = 1
    @Volatile var processedFrames = 0L
        private set
    @Volatile var bypassedFrames = 0L
        private set

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        channels = numChannels
        reset(sampleRateHz)
    }

    override fun reset(newRate: Int) {
        destroy(state)
        state = create()
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        // RNNoise expects full-band mono at 48 kHz. Preserve audio on unsupported
        // device formats; WebRTC's base suppression remains enabled as fallback.
        if (channels == 1 && numFrames == 480 && processFrame(state, buffer, numFrames)) {
            processedFrames++
        } else {
            bypassedFrames++
        }
    }

    fun close() { destroy(state); state = 0 }
    private external fun create(): Long
    private external fun destroy(handle: Long)
    private external fun processFrame(handle: Long, buffer: ByteBuffer, frames: Int): Boolean

    companion object {
        private var processor: MeshNoiseProcessor? = null
        private var adapter: AudioProcessingAdapter? = null
        private val available by lazy {
            runCatching { System.loadLibrary("mesh_noise"); true }.getOrDefault(false)
        }

        fun bind(engine: FlutterEngine) {
            MethodChannel(engine.dartExecutor.binaryMessenger, "meshchat/noise_suppression")
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "configure" -> {
                            val enabled = call.argument<Boolean>("enabled") == true
                            runCatching { configure(enabled) }.fold(
                                { result.success(it) },
                                { result.error("noise_unavailable", "Local noise filter unavailable", null) })
                        }
                        "status" -> result.success(mapOf(
                            "attached" to (processor != null),
                            "processed_frames" to (processor?.processedFrames ?: 0L),
                            "bypassed_frames" to (processor?.bypassedFrames ?: 0L)))
                        else -> result.notImplemented()
                    }
                }
        }

        private fun configure(enabled: Boolean): Boolean {
            if (!enabled) {
                processor?.let { adapter?.removeProcessor(it); it.close() }
                processor = null
                adapter = null
                return false
            }
            if (!available) return false
            val target = FlutterWebRTCPlugin.sharedSingleton?.audioProcessingController?.capturePostProcessing ?: return false
            if (adapter === target && processor != null) return true
            configure(false)
            val next = MeshNoiseProcessor()
            if (next.state == 0L) { next.close(); return false }
            target.addProcessor(next)
            adapter = target
            processor = next
            // Avoid applying a device-specific hardware denoiser as a third
            // layer on top of WebRTC and RNNoise. Keep hardware AEC unchanged.
            FlutterWebRTCPlugin.sharedSingleton?.audioDeviceModule?.setNoiseSuppressorEnabled(false)
            return true
        }
    }
}
