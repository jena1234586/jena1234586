# TensorFlow Lite
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-keep class org.tensorflow.lite.flex.** { *; }

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep TensorFlow Lite GPU Delegate classes
-keep class org.tensorflow.lite.gpu.GpuDelegateFactory { *; }
-keep class org.tensorflow.lite.gpu.GpuDelegateFactory$Options { *; }
-keep class org.tensorflow.lite.gpu.GpuDelegate { *; }

# Keep all TensorFlow Lite classes
-keep class org.tensorflow.** { *; }

# Don't warn about missing classes that are optional
-dontwarn org.tensorflow.lite.gpu.**

