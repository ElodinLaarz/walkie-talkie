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

            signingConfig = signingConfigs.getByName("release")
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
