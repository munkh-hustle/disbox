import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 1. Directly read local.properties to bypass Flutter plugin caching issues
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localProperties.load(FileInputStream(localPropertiesFile))
}

// 2. Get the NDK version from local.properties, or fallback to the version you confirmed is installed
val customNdkVersion = localProperties.getProperty("flutter.ndkVersion") ?: "30.0.16248370"

android {
    namespace = "com.example.flutter_disbox"
    compileSdk = flutter.compileSdkVersion
    
    // 3. Apply the safely resolved NDK version
    ndkVersion = customNdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
        isCoreLibraryDesugaringEnabled = true
    }
    
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_21.toString()
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