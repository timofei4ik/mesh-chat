import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.firebase.crashlytics")
    id("com.google.firebase.firebase-perf")
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
    compileSdk = maxOf(36, flutter.compileSdkVersion)
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
        targetSdk = maxOf(36, flutter.targetSdkVersion)
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

    signingConfigs {
        val keyPropertiesFile = rootProject.file("key.properties")
        if (keyPropertiesFile.exists()) {
            val keyProperties = Properties().apply {
                keyPropertiesFile.inputStream().use(::load)
            }
            create("release") {
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
    implementation("com.google.firebase:firebase-crashlytics")
    implementation("com.google.firebase:firebase-perf")
}
