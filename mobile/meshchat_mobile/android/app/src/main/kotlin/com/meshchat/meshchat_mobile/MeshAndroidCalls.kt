package com.meshchat.meshchat_mobile

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.os.Vibrator
import android.os.VibrationEffect
import androidx.core.app.NotificationManagerCompat
import com.hiennv.flutter_callkit_incoming.CallkitIncomingBroadcastReceiver
import com.hiennv.flutter_callkit_incoming.getDataActiveCalls
import com.hiennv.flutter_callkit_incoming.CallkitEventCallback
import com.hiennv.flutter_callkit_incoming.Data
import com.hiennv.flutter_callkit_incoming.FlutterCallkitIncomingPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Native call presentation and short-lived actions survive a Flutter cold start. */
object MeshAndroidCalls : CallkitEventCallback {
    const val ENGINE = "meshchat_calls"
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var activityAttached = false
    private val prefs get() = context.getSharedPreferences("meshchat_system_calls", Context.MODE_PRIVATE)

    fun initialize(applicationContext: Context) {
        context = applicationContext.applicationContext
        FlutterCallkitIncomingPlugin.registerEventCallback(this)
    }

    fun ensureEngine(): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE)?.let { return it }
        return FlutterEngine(context).also {
            FlutterEngineCache.getInstance().put(ENGINE, it)
            bind(it)
            it.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
    }

    fun bind(engine: FlutterEngine, withActivity: Boolean = false) {
        MeshNoiseProcessor.bind(engine)
        activityAttached = withActivity
        FlutterEngineCache.getInstance().put(ENGINE, engine)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "meshchat/android_calls").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                val id = args["call_id"]?.toString().orEmpty()
                when (call.method) {
                    "preferences" -> {
                        prefs.edit().putBoolean("enabled", args["enabled"] != false)
                            .putBoolean("sound", args["sound"] != false)
                            .putBoolean("vibration", args["vibration"] != false).apply()
                        result.success(null)
                    }
                    "background" -> result.success(!activityAttached)
                    "clear" -> {
                        getDataActiveCalls(context).forEach { end(it.id) }
                        pendingActions().forEach { end(it["call_id"].toString()) }
                        result.success(null)
                    }
                    "incoming" -> {
                        val payload = args.entries.associate { it.key.toString() to it.value.toString() }
                        result.success(show(payload))
                    }
                    "ended" -> { end(id); result.success(null) }
                    "answered" -> {
                        getDataActiveCalls(context).firstOrNull { it.id == id && !it.isAccepted }?.let {
                            context.sendBroadcast(CallkitIncomingBroadcastReceiver.getIntentAccept(context, it.toBundle()))
                        }
                        result.success(null)
                    }
                    "actions" -> result.success(pendingActions())
                    "ack" -> {
                        val pending = prefs.getString("action:$id", null)
                        if (pending != null && JSONObject(pending).optString("action") == args["action"]) {
                            prefs.edit().remove("action:$id").apply()
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun show(payload: Map<String, String>): Boolean {
        val id = payload["call_id"].orEmpty()
        if (id.isBlank() || id.length > 128) return false
        if (!prefs.getBoolean("enabled", true)) return false
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        prune()
        if (prefs.getLong("ended:$id", 0) > System.currentTimeMillis()) return true
        if (prefs.getLong("shown:$id", 0) > System.currentTimeMillis()) return true
        val plugin = FlutterCallkitIncomingPlugin.getInstance() ?: return false
        if (getDataActiveCalls(context).any { it.id != id }) return false
        val now = System.currentTimeMillis()
        val expires = minOf(payload["expires_at"]?.toLongOrNull() ?: (now + 45_000L), now + 45_000L)
        if (expires <= now) return false
        val extra = hashMapOf<String, Any?>(
            "source_node" to payload["source_node"].orEmpty(),
            "group_id" to payload["group_id"].orEmpty(),
            "expires_at" to expires,
        )
        val data = Data(hashMapOf(
            "id" to id,
            "nameCaller" to payload["title"].orEmpty().ifBlank { "MeshChat" },
            "appName" to "MeshChat",
            "duration" to (expires - now),
            "extra" to extra,
            "textAccept" to "Answer",
            "textDecline" to "Decline",
            "android" to hashMapOf(
                "isCustomNotification" to false,
                "isShowFullLockedScreen" to true,
                "isShowCallID" to false,
                "backgroundColor" to "#101A23",
                "actionColor" to "#39C9DB",
                "textColor" to "#FFFFFF",
                "ringtonePath" to if (payload["sound"] == "false") "" else "system_ringtone_default",
                "incomingCallNotificationChannelName" to "Incoming calls",
            ),
            "missedCallNotification" to hashMapOf("showNotification" to false),
        ))
        prefs.edit().putLong("shown:$id", expires).apply()
        // Dispatch synchronously to apply alert preferences and verify creation
        // before reporting success to Flutter (the dependency is version-pinned).
        CallkitIncomingBroadcastReceiver().onReceive(context,
            CallkitIncomingBroadcastReceiver.getIntentIncoming(context, data.toBundle()))
        val sound = payload["sound"]?.toBooleanStrictOrNull() ?: prefs.getBoolean("sound", true)
        val vibration = payload["vibration"]?.toBooleanStrictOrNull() ?: prefs.getBoolean("vibration", true)
        @Suppress("DEPRECATION")
        val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        if (!sound) {
            plugin.getCallkitSoundPlayerManager()?.stop()
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            if (vibration && audio.ringerMode != android.media.AudioManager.RINGER_MODE_SILENT) {
                val pattern = LongArray(46) { if (it == 0) 0 else 1000 }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator?.vibrate(VibrationEffect.createWaveform(pattern, -1))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator?.vibrate(pattern, -1)
                }
            }
        } else if (!vibration) vibrator?.cancel()
        val shown = getDataActiveCalls(context).any { it.id == id }
        if (!shown) prefs.edit().remove("shown:$id").apply()
        return shown
    }

    fun canUseFallback(id: String): Boolean =
        prefs.getBoolean("enabled", true) && prefs.getLong("ended:$id", 0) <= System.currentTimeMillis() &&
            getDataActiveCalls(context).none { it.id != id }

    fun end(id: String) {
        if (id.isBlank()) return
        val current = getDataActiveCalls(context).firstOrNull { it.id == id }
        if (current != null) cancelVibration()
        prefs.edit().putLong("ended:$id", System.currentTimeMillis() + 120_000L)
            .remove("shown:$id").remove("action:$id").apply()
        if (current != null) FlutterCallkitIncomingPlugin.getInstance()?.endCall(current)
    }

    override fun onCallEvent(event: CallkitEventCallback.CallEvent, callData: Bundle) {
        val data = Data.fromBundle(callData)
        val id = data.id
        if (id.isBlank() || prefs.getLong("ended:$id", 0) > System.currentTimeMillis()) return
        cancelVibration()
        val action = when (event) {
            CallkitEventCallback.CallEvent.ACCEPT -> "answer"
            CallkitEventCallback.CallEvent.DECLINE -> "decline"
            CallkitEventCallback.CallEvent.END -> "end"
        }
        val expires = if (action == "answer") prefs.getLong("shown:$id", 0)
            else System.currentTimeMillis() + 45_000L
        if (expires <= System.currentTimeMillis()) { end(id); return }
        val value = JSONObject().put("call_id", id).put("action", action).put("expires_at", expires)
        prefs.edit().putString("action:$id", value.toString()).apply()
        channel?.invokeMethod("actionsAvailable", null)
        Handler(Looper.getMainLooper()).postDelayed({
            val pending = prefs.getString("action:$id", null)
            if (pending != null && JSONObject(pending).optLong("expires_at") <= System.currentTimeMillis()) {
                end(id)
            }
        }, (expires - System.currentTimeMillis()).coerceAtLeast(1L))
    }

    private fun prune() {
        val now = System.currentTimeMillis()
        val edit = prefs.edit()
        val expiredCalls = mutableListOf<String>()
        prefs.all.forEach { (key, value) ->
            if (!key.startsWith("shown:") && !key.startsWith("ended:") && !key.startsWith("action:")) return@forEach
            val expires = if (value is Long) value else runCatching {
                JSONObject(value.toString()).optLong("expires_at")
            }.getOrDefault(0)
            if (expires <= now) {
                edit.remove(key)
                if (key.startsWith("action:")) expiredCalls.add(key.removePrefix("action:"))
            }
        }
        edit.apply()
        expiredCalls.forEach { end(it) }
    }

    @Suppress("DEPRECATION")
    private fun cancelVibration() {
        (context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)?.cancel()
    }

    private fun pendingActions(): List<Map<String, Any>> {
        prune()
        return prefs.all.filterKeys { it.startsWith("action:") }.values.mapNotNull { value ->
            runCatching {
                val json = JSONObject(value.toString())
                mapOf("call_id" to json.getString("call_id"), "action" to json.getString("action"), "expires_at" to json.getLong("expires_at"))
            }.getOrNull()
        }
    }
}
