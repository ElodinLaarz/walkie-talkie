# Walkie-Talkie ProGuard Rules
# Keep rules for R8 minification + shrinking

# ============================================================================
# JNI: Keep all native methods and classes called from C++
# ============================================================================

# Keep all native method declarations
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep specific JNI classes and their callback methods invoked from C++
-keep class com.elodin.walkie_talkie.AudioEngineManager { *; }
-keep class com.elodin.walkie_talkie.AudioMixerManager { *; }
-keep class com.elodin.walkie_talkie.PeerAudioManager { *; }

-keepclassmembers class com.elodin.walkie_talkie.MainActivity {
    void sendLocalTalkingEvent(boolean);
    void sendAudioError(java.lang.String);
}

# Keep GATT managers - accessed via platform channel and may use reflection
-keep class com.elodin.walkie_talkie.GattClientManager { *; }
-keep class com.elodin.walkie_talkie.GattServerManager { *; }

# ============================================================================
# flutter_blue_plus: Bluetooth LE library keep rules
# ============================================================================

# Keep FlutterBluePlus plugin classes - used via platform channels
-keep class com.lib.flutter_blue_plus.** { *; }

# Keep Bluetooth GATT classes - reflection and JNI dependencies
-keep class android.bluetooth.** { *; }

# ============================================================================
# sqflite: Local database keep rules
# ============================================================================

# Keep sqflite plugin classes
-keep class com.tekartik.sqflite.** { *; }

# ============================================================================
# Flutter framework keep rules
# ============================================================================

# Keep Flutter embedding entry points
-keep class io.flutter.app.FlutterApplication { *; }
-keep class io.flutter.plugin.common.** { *; }
-keep class io.flutter.plugin.platform.** { *; }
-keep class io.flutter.embedding.engine.** { *; }

# Keep generated plugin registrant
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# Keep method channel handlers
-keepclassmembers class * {
    @io.flutter.embedding.engine.dart.DartExecutor$DartEntrypoint *;
}

# ============================================================================
# AndroidX and Android SDK keep rules
# ============================================================================

# Keep androidx.media for MediaSession + NotificationCompat.MediaStyle
-keep class androidx.media.** { *; }
-keep interface androidx.media.** { *; }

# Keep Android components that may be accessed reflectively
-keepclassmembers class * extends android.app.Activity { *; }
-keepclassmembers class * extends android.app.Service { *; }
-keepclassmembers class * extends android.content.BroadcastReceiver { *; }

# ============================================================================
# General Android best practices
# ============================================================================

# Keep line numbers for debugging stack traces
-keepattributes SourceFile,LineNumberTable

# Keep generic signatures for reflection
-keepattributes Signature

# Keep annotations
-keepattributes *Annotation*

# Keep exceptions
-keepattributes Exceptions

# Don't warn about missing platform classes
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**
-dontwarn com.google.errorprone.**

# ============================================================================
# Oboe audio library
# ============================================================================

# Oboe is statically linked C++ - no special keep rules needed for symbols
# R8 doesn't touch .so files, only Java/Kotlin bytecode

# ============================================================================
# Opus codec library
# ============================================================================

# Opus is vendored in cpp/opus/ and statically linked - no Java layer to keep
