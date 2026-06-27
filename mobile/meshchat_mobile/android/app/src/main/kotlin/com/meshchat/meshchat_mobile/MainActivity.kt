package com.meshchat.meshchat_mobile

import android.content.Context
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val proximityChannel = "meshchat/proximity_screen"
    private var proximityWakeLock: PowerManager.WakeLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, proximityChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable" -> {
                        enableProximityScreenOff()
                        result.success(null)
                    }
                    "disable" -> {
                        disableProximityScreenOff()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun enableProximityScreenOff() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = proximityWakeLock ?: powerManager.newWakeLock(
            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
            "MeshChat:ProximityScreenOff"
        ).also { proximityWakeLock = it }
        if (!wakeLock.isHeld) {
            wakeLock.acquire()
        }
    }

    private fun disableProximityScreenOff() {
        val wakeLock = proximityWakeLock ?: return
        if (wakeLock.isHeld) {
            wakeLock.release()
        }
    }

    override fun onDestroy() {
        disableProximityScreenOff()
        super.onDestroy()
    }
}
