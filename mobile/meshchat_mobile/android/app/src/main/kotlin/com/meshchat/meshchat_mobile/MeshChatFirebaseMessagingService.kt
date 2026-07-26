package com.meshchat.meshchat_mobile

import android.app.NotificationManager
import android.content.Context
import com.google.firebase.messaging.RemoteMessage
import com.google.firebase.messaging.FirebaseMessagingService

class MeshChatFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        if (message.data["type"] != "call_end") return
        val callId = message.data["call_id"].orEmpty()
        if (callId.isEmpty()) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel("meshchat_call_$callId", 0)
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
    }
}
