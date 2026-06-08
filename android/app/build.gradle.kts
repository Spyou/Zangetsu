import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is read from android/key.properties (kept out of git). When
// that file is absent the build falls back to debug signing, so `flutter run`
// and CI still work without the release keystore.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.spyou.watch_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.spyou.watch_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Drop x86/x86_64 (emulator-only) native libs from every output — including
    // the prebuilt plugin lib (libmpv) that abiFilters / --target-platform do
    // NOT strip. This is the reliable lever for the fat APK + AAB, and it's
    // harmless to the per-ABI (arm) split builds.
    packaging {
        jniLibs {
            excludes += listOf("**/x86/**", "**/x86_64/**")
        }
        // CloudStream library (feature/extra) pulls okhttp/jspecify/etc. that
        // clash on duplicate META-INF entries — drop the non-essential ones.
        resources {
            excludes += listOf(
                "META-INF/*.kotlin_module",
                "META-INF/INDEX.LIST",
                "META-INF/io.netty.versions.properties",
                "META-INF/*.version",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/DEPENDENCIES",
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
            )
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore)
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")

            // R8: shrink + obfuscate the Java/Kotlin code and strip unused
            // resources. (The bulk of the app is native libs + AOT Dart, which
            // R8 can't touch — the real size win is the per-ABI build.)
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

// ── CloudStream extension support (feature/extra) ─────────────────────────────
// Bundles the CloudStream runtime so .cs3 plugins can be DexClassLoaded against
// it. GPL-3.0 — see docs/cloudstream-integration-spec.md §7.
dependencies {
    implementation("com.github.recloudstream.cloudstream:library:v4.7.0")
}
