# R8 / ProGuard rules for the release build.
#
# Flutter, the camera plugin, sqflite, ML Kit and the other plugins ship their
# own consumer rules inside their AARs, so most of this file is intentionally
# empty. Rules are added here only when `flutter build apk --release` reports
# a missing class or a runtime crash that only happens with minification.

# ML Kit barcode scanning (bundled model): keep the public API surface that the
# plugin reaches through reflection-like channel calls.
-keep class com.google.mlkit.vision.barcode.** { *; }
-keep class com.google.mlkit.vision.common.** { *; }
-dontwarn com.google.mlkit.**

# Keep line numbers in crash stack traces (file names are hidden).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
