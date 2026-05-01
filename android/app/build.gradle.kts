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
        // Auto-derive versionCode in CI from VERSION_CODE (explicit override) or
        // GITHUB_RUN_NUMBER (one-per-CI-run, monotonic). Local builds and any CI
        // run without those vars fall back to the static `+N` from pubspec.yaml,
        // surfaced via flutter.versionCode. Play rejects duplicate versionCodes,
        // so this is what lets back-to-back release builds upload without a
        // manual pubspec bump.
        versionCode = (System.getenv("VERSION_CODE")?.toIntOrNull()
            ?: System.getenv("GITHUB_RUN_NUMBER")?.toIntOrNull()
            ?: flutter.versionCode)
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
            // Support environment variables for CI (takes precedence over key.properties)
            val envKeystorePath = System.getenv("KEYSTORE_PATH")
            val envKeystorePassword = System.getenv("KEYSTORE_PASSWORD")
            val envKeyAlias = System.getenv("KEY_ALIAS")
            val envKeyPassword = System.getenv("KEY_PASSWORD")

            val keyPropsFile = rootProject.file("key.properties")
            val hasEnvConfig = envKeystorePath != null && envKeystorePassword != null &&
                               envKeyAlias != null && envKeyPassword != null
            val hasFileConfig = keyPropsFile.exists()

            when {
                hasEnvConfig -> {
                    storeFile = file(envKeystorePath)
                    storePassword = envKeystorePassword
                    keyAlias = envKeyAlias
                    keyPassword = envKeyPassword
                }
                hasFileConfig -> {
                    val keyProps = java.util.Properties()
                    keyPropsFile.inputStream().use { keyProps.load(it) }
                    keyAlias = keyProps.getProperty("keyAlias")
                    keyPassword = keyProps.getProperty("keyPassword")
                    storeFile = keyProps.getProperty("storeFile")?.let { rootProject.file(it) }
                    storePassword = keyProps.getProperty("storePassword")
                }
                else -> {
                    // No signing config available - will fail at build time if release is requested
                }
            }
        }
    }

    buildTypes {
        release {
            // Fail fast if release build is requested but no signing config is available
            // Only check when a release task is actually being executed
            val isReleaseBuild = gradle.startParameter.taskNames.any {
                it.contains("Release", ignoreCase = true) ||
                it.contains("assembleRelease", ignoreCase = true) ||
                it.contains("bundleRelease", ignoreCase = true)
            }

            if (isReleaseBuild) {
                val envKeystorePath = System.getenv("KEYSTORE_PATH")
                val envKeystorePassword = System.getenv("KEYSTORE_PASSWORD")
                val envKeyAlias = System.getenv("KEY_ALIAS")
                val envKeyPassword = System.getenv("KEY_PASSWORD")
                val hasEnvConfig = envKeystorePath != null && envKeystorePassword != null &&
                                   envKeyAlias != null && envKeyPassword != null
                val hasFileConfig = rootProject.file("key.properties").exists()

                if (!hasEnvConfig && !hasFileConfig) {
                    throw GradleException(
                        "Release signing configuration is missing. Either:\n" +
                        "  1. Create 'key.properties' in the project root with:\n" +
                        "     storeFile=path/to/keystore.jks\n" +
                        "     storePassword=<password>\n" +
                        "     keyAlias=<alias>\n" +
                        "     keyPassword=<password>\n" +
                        "  OR\n" +
                        "  2. Set environment variables:\n" +
                        "     KEYSTORE_PATH, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD"
                    )
                }
            }

            signingConfig = signingConfigs.getByName("release")
        }
    }

    // Explicit AAB split configuration. AGP currently defaults all three to
    // enableSplit = true, but pinning them keeps a future default change from
    // silently regressing per-device download size — the whole reason this app
    // ships an AAB instead of a fat APK is to deliver only the ABI / density /
    // language slice each device needs.
    bundle {
        language {
            enableSplit = true
        }
        density {
            enableSplit = true
        }
        abi {
            enableSplit = true
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
