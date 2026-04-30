plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.elodin.walkie_talkie"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.elodin.walkie_talkie"
        // Android 13+ required for Bluetooth LE Audio APIs
        minSdk = 33
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // NDK configuration for Oboe audio library
        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                arguments += listOf("-DANDROID_STL=c++_shared")
            }
        }
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    // CMake configuration for native audio processing
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        create("release") {
            val keyPropsFile = rootProject.file("key.properties")
            if (keyPropsFile.exists()) {
                val keyProps = java.util.Properties()
                keyPropsFile.inputStream().use { keyProps.load(it) }
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
                storeFile = keyProps.getProperty("storeFile")?.let { rootProject.file(it) }
                storePassword = keyProps.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (rootProject.file("key.properties").exists()) "release" else "debug"
            )
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    // androidx.media gives us MediaSessionCompat + NotificationCompat.MediaStyle.
    // Pulled in for issue #97: an active MediaSession with STATE_PLAYING is what
    // tells Android 11+ FGS audio policy that we're "actively engaging" the user
    // so the mic stream isn't suppressed when the screen is off.
    implementation("androidx.media:media:1.7.0")
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
