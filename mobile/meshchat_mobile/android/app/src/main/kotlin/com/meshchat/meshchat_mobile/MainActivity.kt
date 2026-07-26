package com.meshchat.meshchat_mobile

import android.content.Context
import android.content.Intent
import android.os.PowerManager
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val proximityChannel = "meshchat/proximity_screen"
    private val androidPushChannel = "meshchat/android_push"
    private var pushMethodChannel: MethodChannel? = null
    private var pendingNotificationLaunch: Map<String, String>? = null
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
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            androidPushChannel
        )
        pushMethodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> initializeAndroidPush(call.arguments, result)
                "consumeNotificationLaunch" -> {
                    val payload = pendingNotificationLaunch ?: notificationPayload(intent)
                    pendingNotificationLaunch = null
                    result.success(payload)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = notificationPayload(intent) ?: return
        pendingNotificationLaunch = payload
        pushMethodChannel?.invokeMethod("notificationOpened", payload)
    }

    private fun notificationPayload(intent: Intent?): Map<String, String>? {
        val extras = intent?.extras ?: return null
        val payload = mapOf(
            "packet_type" to (extras.getString("type") ?: ""),
            "source_node" to (extras.getString("source_node") ?: ""),
            "group_id" to (extras.getString("group_id") ?: ""),
            "call_id" to (extras.getString("call_id") ?: "")
        )
        return if (payload.values.all { it.isBlank() }) null else payload
    }

    private fun initializeAndroidPush(arguments: Any?, result: MethodChannel.Result) {
        try {
            val app = MeshChatFirebase.configure(this, arguments as? Map<*, *>)
            if (app == null) {
                result.success(null)
                return
            }
            val cached = getSharedPreferences(
                MeshChatFirebaseMessagingService.PREFERENCES,
                Context.MODE_PRIVATE
            ).getString(MeshChatFirebaseMessagingService.TOKEN_KEY, null)
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                if (!task.isSuccessful) {
                    if (cached != null) result.success(cached)
                    else result.error("fcm_token_failed", task.exception?.message, null)
                    return@addOnCompleteListener
                }
                val token = task.result
                getSharedPreferences(
                    MeshChatFirebaseMessagingService.PREFERENCES,
                    Context.MODE_PRIVATE
                ).edit().putString(
                    MeshChatFirebaseMessagingService.TOKEN_KEY,
                    token
                ).apply()
                result.success(token)
            }
        } catch (error: Exception) {
            result.error("fcm_init_failed", error.message, null)
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
