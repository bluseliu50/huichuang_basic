plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.huichuang.huichuang_basic"
    // flutter_secure_storage v11 compiles against SDK 37 (backward
    // compatible); pin it instead of following flutter.compileSdkVersion (36).
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.huichuang.huichuang_basic"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // Fixed signing identity: CI decodes the keystore from the
            // KEYSTORE_BASE64 secret and points HC_KEYSTORE_PATH at it, so
            // every shipped APK is signed with the same certificate and
            // updates install over previous ones. Absent locally, so plain
            // local builds keep using the debug keys.
            val ksPath = System.getenv("HC_KEYSTORE_PATH")
            if (ksPath != null) {
                storeFile = file(ksPath)
                storePassword = System.getenv("HC_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("HC_KEY_ALIAS")
                keyPassword = System.getenv("HC_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        // Distinct package ids so debug/profile builds install beside the
        // release app instead of failing with INSTALL_FAILED_UPDATE_INCOMPATIBLE
        // (same id, different signing keys wipes the release app's data).
        debug {
            applicationIdSuffix = ".debug"
        }
        getByName("profile") {
            applicationIdSuffix = ".profile"
        }
        release {
            signingConfig = if (System.getenv("HC_KEYSTORE_PATH") != null) {
                signingConfigs.getByName("release")
            } else {
                // Signing with the debug keys for now, so `flutter run --release` works.
                signingConfigs.getByName("debug")
            }
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
