-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Zachowaj klasy ML Kit
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keepclassmembers class * {
    @com.google.mlkit.** <methods>;
}
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**
