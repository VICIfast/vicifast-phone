import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Resolve release-signing material from either:
//   1. android/key.properties (preferred for local dev — never committed)
//   2. environment variables (used by CI)
// Falls back to the debug keystore if neither is present, so `flutter run`
// still works in fresh clones.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) load(FileInputStream(f))
}

fun keyProp(name: String, env: String): String? =
    keyProps.getProperty(name) ?: System.getenv(env)

val haveReleaseKey =
    keyProp("storeFile", "ANDROID_KEYSTORE_FILE") != null ||
    System.getenv("ANDROID_KEYSTORE_BASE64") != null

android {
    namespace = "io.vicifast.vicifast_phone"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.vicifast.phone"
        minSdk = 26          // Android 8.0 — full ConnectionService + foreground service types
        targetSdk = 36       // Play Store requires ≥35 for new releases (Aug 2025); match compileSdk
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    // Two ways out: a direct download that updates itself from vicifast.com,
    // and a Google Play build that doesn't (Play forbids self-updates and
    // restricts the install-packages permission).
    // Build with `flutter build apk --flavor direct` or `--flavor play`.
    flavorDimensions += "distribution"
    productFlavors {
        create("direct") { dimension = "distribution" }
        create("play") { dimension = "distribution" }
    }

    signingConfigs {
        if (haveReleaseKey) {
            create("release") {
                val storeFileName = keyProp("storeFile", "ANDROID_KEYSTORE_FILE")
                    ?: "upload-keystore.jks"
                storeFile = file(storeFileName)
                storePassword = keyProp("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = keyProp("keyAlias", "ANDROID_KEY_ALIAS")
                keyPassword = keyProp("keyPassword", "ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (haveReleaseKey)
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
        resources.excludes += setOf(
            "META-INF/AL2.0",
            "META-INF/LGPL2.1",
            "META-INF/DEPENDENCIES"
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Linphone SDK (Belledonne Communications) — provides liblinphone Java/Kotlin bindings + native libs
    implementation("org.linphone:linphone-sdk-android:5.4.127")

    // AndroidX
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")

    // Firebase (VoIP wake-up via high-priority FCM data messages)
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-messaging-ktx")
}

flutter {
    source = "../.."
}
