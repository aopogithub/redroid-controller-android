# Flutter-specific ProGuard rules
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# Keep MethodChannel handler
-keep class com.redroidcontroller.redroid_controller.** { *; }

# Keep pure-Dart ADB classes
-keep class * extends io.flutter.plugin.common.MethodChannel$MethodCallHandler { *; }

# Keep MediaCodec
-keep class android.media.** { *; }

# Suppress Play Core missing classes (not used but referenced by Flutter)
-dontwarn com.google.android.play.core.**
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# Suppress warnings for missing annotations etc
-dontwarn javax.annotation.**
