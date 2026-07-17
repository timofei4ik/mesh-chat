package com.meshchat.meshchat_mobile

import com.google.firebase.messaging.FirebaseMessagingService

class MeshChatFirebaseMessagingService : FirebaseMessagingService() {
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
