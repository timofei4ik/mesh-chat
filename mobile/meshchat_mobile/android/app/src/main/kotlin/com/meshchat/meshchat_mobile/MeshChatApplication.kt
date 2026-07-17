package com.meshchat.meshchat_mobile

import android.app.Application
import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions

class MeshChatApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        MeshChatFirebase.configure(this)
    }
}

object MeshChatFirebase {
    fun configure(context: Context, overrides: Map<*, *>? = null): FirebaseApp? {
        FirebaseApp.getApps(context).firstOrNull()?.let { return it }

        val apiKey = value(overrides, "apiKey", BuildConfig.MESH_FIREBASE_API_KEY)
        val appId = value(overrides, "appId", BuildConfig.MESH_FIREBASE_APP_ID)
        val senderId = value(
            overrides,
            "senderId",
            BuildConfig.MESH_FIREBASE_MESSAGING_SENDER_ID,
        )
        val projectId = value(overrides, "projectId", BuildConfig.MESH_FIREBASE_PROJECT_ID)
        if (apiKey.isEmpty() || appId.isEmpty() || senderId.isEmpty() || projectId.isEmpty()) {
            return null
        }

        val builder = FirebaseOptions.Builder()
            .setApiKey(apiKey)
            .setApplicationId(appId)
            .setGcmSenderId(senderId)
            .setProjectId(projectId)
        val storageBucket = value(
            overrides,
            "storageBucket",
            BuildConfig.MESH_FIREBASE_STORAGE_BUCKET,
        )
        if (storageBucket.isNotEmpty()) builder.setStorageBucket(storageBucket)
        return FirebaseApp.initializeApp(context, builder.build())
    }

    private fun value(overrides: Map<*, *>?, key: String, fallback: String): String {
        return overrides?.get(key)?.toString()?.trim().orEmpty().ifEmpty { fallback.trim() }
    }
}
