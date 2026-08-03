package com.meshchat.meshchat_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class MeshChatFirebaseMessagingService : FirebaseMessagingService() {
    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannels()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        val data = message.data
        val type = data["type"].orEmpty()
        val callId = data["call_id"].orEmpty()
        if (type == "call_end" || data["cancel"] == "true") {
            cancelCallNotification(callId)
            return
        }
        showNotification(message)
    }

    private fun showNotification(message: RemoteMessage) {
        ensureNotificationChannels()
        val data = message.data
        val type = data["type"].orEmpty()
        val isCall = type == "call_offer"
        val callId = data["call_id"].orEmpty()
        val packetId = data["packet_id"].orEmpty()
        val channelId = if (isCall) CALL_CHANNEL_ID else MESSAGE_CHANNEL_ID
        val title = data["title"] ?: message.notification?.title ?: "MeshChat"
        val body = data["body"] ?: message.notification?.body ?: "New message"
        val contentIntent = notificationIntent(data, packetId.ifEmpty { callId })

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(contentIntent)
            .setCategory(if (isCall) Notification.CATEGORY_CALL else Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setAutoCancel(!isCall)
            .setOngoing(isCall)
            .setOnlyAlertOnce(false)

        if (isCall) {
            builder.setFullScreenIntent(contentIntent, true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                builder.setTimeoutAfter(CALL_TIMEOUT_MILLIS)
            }
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(Notification.PRIORITY_HIGH)
            @Suppress("DEPRECATION")
            builder.setDefaults(Notification.DEFAULT_SOUND or Notification.DEFAULT_VIBRATE)
        }

        val tag = if (isCall) {
            callNotificationTag(callId)
        } else {
            data["tag"].orEmpty().ifEmpty { "meshchat_message" }
        }
        val notificationId = if (isCall) 0 else stableNotificationId(packetId, message.messageId)
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            manager.notify(tag, notificationId, builder.build())
        } catch (_: SecurityException) {
            // Android 13+ can reject notifications until the user grants permission.
        }
    }

    private fun notificationIntent(data: Map<String, String>, identity: String): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("type", data["type"].orEmpty())
            putExtra("source_node", data["source_node"].orEmpty())
            putExtra("group_id", data["group_id"].orEmpty())
            putExtra("call_id", data["call_id"].orEmpty())
        }
        return PendingIntent.getActivity(
            this,
            identity.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun cancelCallNotification(callId: String) {
        if (callId.isEmpty()) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(callNotificationTag(callId), 0)
    }

    private fun ensureNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val messages = NotificationChannel(
            MESSAGE_CHANNEL_ID,
            "MeshChat messages",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "New messages and shared files"
            enableVibration(true)
        }
        val calls = NotificationChannel(
            CALL_CHANNEL_ID,
            "MeshChat calls",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Incoming MeshChat calls"
            enableVibration(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannels(listOf(messages, calls))
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        getSharedPreferences(PREFERENCES, MODE_PRIVATE)
            .edit()
            .putString(TOKEN_KEY, token)
            .apply()
    }

    companion object {
        const val PREFERENCES = "meshchat_fcm"
        const val TOKEN_KEY = "registration_token"
        private const val MESSAGE_CHANNEL_ID = "meshchat_messages"
        private const val CALL_CHANNEL_ID = "meshchat_calls"
        private const val CALL_TIMEOUT_MILLIS = 60_000L

        private fun callNotificationTag(callId: String): String = "meshchat_call_$callId"

        private fun stableNotificationId(packetId: String, messageId: String?): Int {
            return packetId.ifEmpty { messageId.orEmpty() }.ifEmpty { "meshchat" }.hashCode()
        }
    }
}
