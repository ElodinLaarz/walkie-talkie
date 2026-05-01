plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("io.sentry.android.gradle")
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
        // Resolve versionCode in this priority order. Play rejects duplicate
        // versionCodes, so the goal is "every CI build uploads with a unique,
        // strictly increasing code, with no manual pubspec bump":
        //
        //   1. VERSION_CODE env var — explicit override (e.g. recreating a
        //      specific historical build, or pinning a hotfix code).
        //   2. GITHUB_RUN_NUMBER * 100 + GITHUB_RUN_ATTEMPT — monotonic per CI
        //      run AND per rerun-of-the-same-run. GITHUB_RUN_NUMBER alone
        //      repeats across reruns of a failed workflow, so a rerun would
        //      collide with the failed attempt's code if that attempt had
        //      uploaded; folding GITHUB_RUN_ATTEMPT in makes reruns distinct.
        //      The multiplier is 100 because GitHub re-runs are capped well
        //      below that in practice (the docs cap automatic reruns at 10),
        //      so adjacent run numbers can't overlap.
        //   3. flutter.versionCode (the static `+N` in pubspec.yaml) — local
        //      builds and any CI run without the GitHub env vars. These never
        //      reach Play, so duplicates here don't matter.
        //
        // Deliberately no maxOf-with-flutter.versionCode clamp: CI runs are
        // already monotonic, and clamping would collapse two consecutive CI
        // builds onto the same flutter.versionCode whenever the static code
        // happens to exceed the run-derived one (Play would then reject the
        // second). If you need to force a specific code in CI, set VERSION_CODE.
        //
        // Math is in Long and validated against Android's hard ceiling
        // (versionCode is a 32-bit signed int but Play caps it at 2.1B) so a
        // pathological GITHUB_RUN_NUMBER can't silently overflow into a
        // negative or out-of-range code that breaks releases late in the build.
        versionCode = run {
            val maxVersionCode = 2_100_000_000L
            fun checked(value: Long, source: String): Int {
                if (value <= 0L || value > maxVersionCode) {
                    throw GradleException(
                        "$source resolved to invalid versionCode $value. " +
                            "versionCode must be in (0, $maxVersionCode]."
                    )
                }
                return value.toInt()
            }
            val explicitRaw = System.getenv("VERSION_CODE")
            if (explicitRaw != null) {
                val explicit = explicitRaw.toLongOrNull()
                    ?: throw GradleException(
                        "VERSION_CODE must be an integer, got: \"$explicitRaw\"."
                    )
                return@run checked(explicit, "VERSION_CODE")
            }
            val runNumber = System.getenv("GITHUB_RUN_NUMBER")?.toLongOrNull()
            val runAttempt = System.getenv("GITHUB_RUN_ATTEMPT")?.toLongOrNull() ?: 1L
            val ciDerived = runNumber?.let { it * 100L + runAttempt }
            if (ciDerived != null) {
                return@run checked(ciDerived, "GITHUB_RUN_NUMBER * 100 + GITHUB_RUN_ATTEMPT")
            }
            checked(flutter.versionCode.toLong(), "flutter.versionCode")
        }
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
            // Enable R8 minification and resource shrinking for release builds
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

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
    //
    // vcsInfo embeds the HEAD commit SHA + remote URL into the AAB metadata so
    // Play Console can deep-link crash stack traces back to the exact source
    // revision — pairs with the R8 mapping upload from #110 for fully
    // deobfuscated, source-linked traces in the Play Console crash dashboard.
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
        vcsInfo {
            include = true
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

// Sentry configuration for crash reporting
// Only enabled when user opts in via Settings (defaults to disabled)
sentry {
    // Upload debug symbols for native crashes (C++ Oboe/Opus code)
    includeNativeSources = true

    // Auto-upload ProGuard/R8 mapping files for deobfuscated Java/Kotlin stacks
    autoUploadProguardMapping = true

    // Controlled by SENTRY_DSN environment variable
    // If not set, Sentry is disabled (respects opt-out default)
    autoUploadNativeSymbols = true

    // Include source context in stack traces
    includeSourceContext = true

    // Trace instrumentation for performance monitoring (opt-in only)
    tracingInstrumentation {
        enabled = false // Disabled by default for privacy
    }
}

dependencies {
    // androidx.media gives us MediaSessionCompat + NotificationCompat.MediaStyle.
    // Pulled in for issue #97: an active MediaSession with STATE_PLAYING is what
    // tells Android 11+ FGS audio policy that we're "actively engaging" the user
    // so the mic stream isn't suppressed when the screen is off.
    implementation("androidx.media:media:1.7.0")

    // Sentry for crash reporting (opt-in via Settings, issue #120)
    // Includes NDK support for native crashes from Oboe/Opus C++ code
    implementation("io.sentry:sentry-android:7.18.1")

    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
