import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // Aniyomi runtime models (Video/Hoster/Track) use kotlinx @Serializable.
    // Version scoped here (not in root settings) so it can't clash with the
    // serialization plugin version a Flutter plugin module pins for itself.
    id("org.jetbrains.kotlin.plugin.serialization") version "2.2.20"
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
        // Required by flutter_local_notifications (uses java.time APIs).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
        // The vendored Aniyomi network layer (OkHttpExtensions.parseAs) uses Kotlin
        // context parameters, a preview feature in Kotlin 2.2.x. Enabling the syntax
        // is additive — existing sources don't use it, so nothing else is affected.
        freeCompilerArgs = freeCompilerArgs + listOf("-Xcontext-parameters")
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

            // Minification stays OFF: CloudStream `.cs3` plugins are external
            // DEX loaded at runtime that link BY NAME against the bundled
            // CloudStream library and its deps (jsoup, jackson, NiceHttp, …).
            // R8 renaming/stripping those classes breaks plugin loading — a repo
            // adds fine but its sources fail to install. Disabling R8 keeps every
            // linked class intact. (The bulk of the app is native libs + AOT
            // Dart, which R8 can't shrink anyway — the size win is the per-ABI
            // split, which we keep.)
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    testOptions {
        // Pull Android resources (manifests, res/) into the JVM unit-test
        // classpath so Robolectric can shadow Activity / Application / etc.
        unitTests.isIncludeAndroidResources = true
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
    // Jackson is already on the RUNTIME classpath (CloudStream library transitive
    // dep). compileOnly lets our clean-room DataStore reference JsonMapper for the
    // plugin-settings API without duplicating Jackson at runtime. Same version.
    compileOnly("com.fasterxml.jackson.module:jackson-module-kotlin:2.13.1")
    // okhttp is on the runtime classpath via NiceHttp (CloudStream transitive);
    // compileOnly lets our clean-room CloudflareKiller implement Interceptor.
    compileOnly("com.squareup.okhttp3:okhttp:4.12.0")
    // okhttp-dnsoverhttps powers the opt-in in-app DNS (Doh.kt → DnsOverHttps).
    // Same okhttp 4.12.0 the CloudStream library already resolves, so this adds
    // no duplicate; declaring it guarantees the class is present at runtime.
    implementation("com.squareup.okhttp3:okhttp-dnsoverhttps:4.12.0")
    // NiceHttp (the `app` global Requests type) is a runtime-transitive dep of
    // the CloudStream library; compileOnly lets PluginHost set app.baseClient to
    // attach our cookie jar without bundling NiceHttp twice. Same version.
    compileOnly("com.github.Blatzar:NiceHttp:0.4.17")
    // AppCompat + Material: required at runtime so a plugin's own settings UI
    // resolves — plugins cast the Context to androidx.appcompat.app.AppCompatActivity
    // and show com.google.android.material BottomSheetDialogFragment/AlertDialog.
    // Only the dedicated CloudStreamSettingsActivity uses these themes; the
    // Flutter UI keeps its own theme, so this doesn't affect the main app.
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    // RecyclerView 1.3.2 (transitive default is 1.1.0, which lacks
    // ViewHolder.getBindingAdapterPosition() — added in 1.2.0). Newer CS plugin
    // settings UIs (e.g. StremioAddon's addon-list) call it and would otherwise
    // crash with NoSuchMethodError. Only the CS settings screens use RecyclerView
    // natively (the Flutter UI doesn't), so this is backward-compatible + isolated.
    implementation("androidx.recyclerview:recyclerview:1.3.2")
    // Core library desugaring — required by flutter_local_notifications.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    // Background "new episode" checks for CloudStream sources (CloudStream's own
    // mechanism): a native periodic worker re-runs PluginHost.load() + notifies.
    implementation("androidx.work:work-runtime-ktx:2.9.1")

    // Torrent streaming engine (native libtorrent). Per-ABI native libs; the
    // in-app updater ships the matching per-ABI APK, so no fat-APK bloat.
    implementation("org.libtorrent4j:libtorrent4j:2.1.0-31")
    implementation("org.libtorrent4j:libtorrent4j-android-arm64:2.1.0-31")
    implementation("org.libtorrent4j:libtorrent4j-android-arm:2.1.0-31")
    // Tiny local HTTP server that streams the downloading file to the player.
    implementation("org.nanohttpd:nanohttpd:2.3.1")

    // ── Aniyomi anime-extension runtime (feature/aniyomi) ─────────────────────────
    // Vendored eu.kanade.tachiyomi.animesource + network compile/run against these.
    // Apache-2.0 — see docs/licenses/aniyomi-extensions-lib-NOTICE.md. okhttp/okio,
    // jsoup, androidx.preference, kotlinx-coroutines and kotlinx-serialization-json
    // are already on the classpath via CloudStream/plugins, so only these are new:
    implementation("io.reactivex:rxjava:1.3.8")             // rx.Observable — RxJava-1 legacy fallback API
    implementation("uy.kohesive.injekt:injekt-core:1.16.1") // uy.kohesive.injekt DI (Maven Central; same as upstream)
    // parseAs()/decodeFromJsonResponse() decode JSON straight off the OkHttp
    // BufferedSource — this is the only kotlinx-serialization piece not already present.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json-okio:1.9.0")
    // androidx.preference backs ConfigurableAnimeSource.setupPreferenceScreen (the
    // PreferenceScreen typealias). Present transitively at runtime; declared here so
    // it's also on the compile classpath. Same version already resolved.
    implementation("androidx.preference:preference-ktx:1.2.1")

    // ── Unit-test harness for AniyomiInjektModulesTest ────────────────────────────
    // Robolectric provides a fake Android environment on the JVM so
    // ApplicationProvider.getApplicationContext() resolves without a device.
    // Pinned to SDK 34 via @Config on the test class (Robolectric 4.12.2's max).
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.12.2")
    testImplementation("androidx.test:core:1.5.0")
    testImplementation("androidx.test:core-ktx:1.5.0")
    // injekt-core is already on the implementation classpath and therefore
    // visible to testImplementation transitively — no extra declaration needed.
}
