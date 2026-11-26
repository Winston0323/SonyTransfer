plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.winston.sony_transfer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.winston.sony_transfer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // DocumentFile wraps the SAF tree URI the user picks as a destination
    // folder, so it can be written to with ordinary streams instead of
    // hand-rolled ContentResolver/DocumentsContract calls.
    implementation("androidx.documentfile:documentfile:1.0.1")
    // Reads the camera as a USB mass-storage device (Multi LUN → one volume
    // per SD card). MTP cannot reach Slot 2 on the A7R III.
    implementation("me.jahnen.libaums:core:0.10.0")
    // Embedded JPEG thumbnails for the USB grid (avoids decoding 42MP frames).
    implementation("androidx.exifinterface:exifinterface:1.3.7")
}
