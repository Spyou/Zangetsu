# R8/ProGuard keep rules for the release build.
#
# Flutter and each plugin ship their own consumer rules (applied automatically),
# so this file only needs a few generic safety keeps. If a release-only crash
# appears, add a targeted -keep here (or set isMinifyEnabled = false to rule R8
# out) and re-test.

# Keep native (JNI) method names so the native libraries can bind to them.
-keepclasseswithmembernames,includedescriptorclasses class * { native <methods>; }

# Enums are often referenced by name (valueOf) via plugins.
-keepclassmembers enum * { *; }

# Metadata other libraries reflect on.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# Flutter embedding / deferred components (defensive; Flutter also adds these).
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**
