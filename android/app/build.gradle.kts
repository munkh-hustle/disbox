plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Q&D: This project has no native (C/C++) code and no dependency requires the NDK,
// so we don't force a specific ndkVersion. AGP would otherwise try to auto-download
// an NDK via sdkmanager, which fails because sdkmanager is deprecated/moved in recent
// Android SDKs ("Package ndk not found"). If you ever add native code, either install
// an NDK manually (Android Studio > SDK Manager > SDK Tools > NDK) or set
// android.ndkVersion to that installed version here.
android {
    namespace = "com.example.flutter_disbox"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.example.flutter_disbox"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }
    
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    
    dependencies {
        coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    }
}

flutter {
    source = "../.."
}

kotlin {
    // compilerOptions DSL: replaces the deprecated android.kotlinOptions { jvmTarget = ... }
    // block, which fails the build under AGP 9 / Kotlin Android plugin 2.x.
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
    }
}