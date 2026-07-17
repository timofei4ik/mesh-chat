import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val meshDartDefines: Map<String, String> = mutableMapOf<String, String>().apply {
    val encodedDefines = project.findProperty("dart-defines") as? String ?: return@apply
    encodedDefines.split(',').forEach { encoded ->
        val decoded = runCatching {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        }.getOrNull() ?: return@forEach
        val separator = decoded.indexOf('=')
        if (separator > 0) {
            put(decoded.substring(0, separator), decoded.substring(separator + 1))
        }
    }
}

fun firebaseDefine(name: String): String =
    meshDartDefines[name]
        .orEmpty()
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")

android {
    namespace = "com.meshchat.meshchat_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.meshchat.meshchat_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "MESH_FIREBASE_API_KEY", "\"${firebaseDefine("MESH_FIREBASE_API_KEY")}\"")
        buildConfigField("String", "MESH_FIREBASE_APP_ID", "\"${firebaseDefine("MESH_FIREBASE_APP_ID")}\"")
        buildConfigField(
            "String",
            "MESH_FIREBASE_MESSAGING_SENDER_ID",
            "\"${firebaseDefine("MESH_FIREBASE_MESSAGING_SENDER_ID")}\"",
        )
        buildConfigField("String", "MESH_FIREBASE_PROJECT_ID", "\"${firebaseDefine("MESH_FIREBASE_PROJECT_ID")}\"")
        buildConfigField(
            "String",
            "MESH_FIREBASE_STORAGE_BUCKET",
            "\"${firebaseDefine("MESH_FIREBASE_STORAGE_BUCKET")}\"",
        )
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation(platform("com.google.firebase:firebase-bom:34.15.0"))
    implementation("com.google.firebase:firebase-messaging")
}
