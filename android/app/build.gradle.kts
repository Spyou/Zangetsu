import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // Aniyomi runtime models (Video/Hoster/Track) use kotlinx @Serializable.
    // Version scoped here (not in root settings) so it can't clash with the
    // serialization plugin version a Flutter plugin module pins for itself.
    id("org.jetbrains.kotlin.plugin.serialization") version "2.2.20"
    // Applied at the bottom only when google-services.json is present (gitignored).
    id("com.google.gms.google-services") apply false
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
            // Extract native libs to the device's lib dir (extractNativeLibs=true).
            // The modern default (false = libs stay uncompressed inside the APK)
            // makes media_kit's libmpv.so lookup fail on some devices (old Android
            // 8, Fire TV) → "Cannot find libmpv.so" → media_kit never initialises
            // → boot black-screen + gray video. Extracting makes the lib reliably
            // findable on every device. Costs a little on-device storage; zero
            // functional change on devices that already worked.
            useLegacyPackaging = true
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

// CloudStream plugins built against the pre-release API inline newer kotlinx
// runtime calls straight into their own dex. FourKHDHub/HDhub4u (and other
// recently-rebuilt Phisher plugins) call kotlinx.coroutines BuildersKt.runBlockingK,
// which only exists from coroutines 1.11.0 — the transitive resolve is 1.10.2, so
// they fail to load ("cs_load_failed / needs a newer app version"). 1.11.0 is a
// backward-compatible superset (still has runBlocking etc.); force it on every
// configuration so the plugin classpath actually links. Plain `implementation`
// only wins the version graph, not the dexed classpath under the build cache.
configurations.configureEach {
    resolutionStrategy {
        force("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
        force("org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.11.0")
        force("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    }
}

// ── CloudStream extension support (feature/extra) ─────────────────────────────
// Bundles the CloudStream runtime so .cs3 plugins can be DexClassLoaded against
// it. GPL-3.0 — see docs/cloudstream-integration-spec.md §7.
dependencies {
    implementation("com.github.recloudstream.cloudstream:library:v4.8.0")
    // Jackson is already on the RUNTIME classpath (CloudStream library transitive
    // dep). compileOnly lets our clean-room DataStore reference JsonMapper for the
    // plugin-settings API without duplicating Jackson at runtime. Same version.
    compileOnly("com.fasterxml.jackson.module:jackson-module-kotlin:2.13.1")
    // okhttp is on the runtime classpath via NiceHttp (CloudStream transitive),
    // which requires 5.3.2 — so that's what actually resolves regardless of what
    // we declare. Pinned to 5.3.2 to match reality; compileOnly lets our
    // clean-room CloudflareKiller implement Interceptor without bundling a copy.
    compileOnly("com.squareup.okhttp3:okhttp:5.3.2")
    // okhttp-dnsoverhttps powers the opt-in in-app DNS (Doh.kt → DnsOverHttps).
    // Matches the okhttp 5.3.2 the CloudStream/NiceHttp graph resolves.
    implementation("com.squareup.okhttp3:okhttp-dnsoverhttps:5.3.2")
    // okhttp-brotli provides okhttp3.brotli.BrotliInterceptor AND (5.x only) the
    // okhttp3.brotli.Brotli DecompressionAlgorithm object. Current Mihon/Aniyomi
    // extensions reference these in their <init>; a version older than the core
    // dies with NoClassDefFoundError (Asura Scans needs okhttp3.brotli.Brotli,
    // absent from 4.12.0). Pinned to 5.3.2 to match the core okhttp the app
    // already resolves. R8 is off (isMinifyEnabled = false) so it isn't stripped.
    implementation("com.squareup.okhttp3:okhttp-brotli:5.3.2")
    // okhttp-zstd (okhttp 5.2+) provides okhttp3.zstd.Zstd — the other half of the
    // new CompressionInterceptor(Brotli, Zstd). Extensions like Asura Scans wire
    // both, so without this they NoClassDefFoundError on okhttp3.zstd.Zstd. Same
    // 5.3.2 as the core; R8 off so it's kept.
    implementation("com.squareup.okhttp3:okhttp-zstd:5.3.2")
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
    // Cloudflare Turnstile parity with Mihon: setUserAgent() uses WebSettingsCompat
    // to set Sec-CH-UA client-hint metadata matching the spoofed UA, so the hints
    // don't contradict it and flag the WebView as a bot.
    implementation("androidx.webkit:webkit:1.11.0")
    implementation("com.google.android.material:material:1.12.0")
    // SAF DocumentFile — used to check if a content:// download still exists.
    implementation("androidx.documentfile:documentfile:1.0.1")
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
    // Google Cast Framework: Chromecast support with the default media receiver.
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")
    implementation("androidx.mediarouter:mediarouter:1.6.0")

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
    // CloudStream (v4.8.0/pre-release) added Ktor, and plugins' extractors now use
    // it for URL parsing — e.g. HDhub4u/FourKHDHub's VidStack calls
    // io.ktor.http.URLUtilsKt/Url/URLProtocol/CodecsKt. This build shipped no Ktor,
    // so those extractors throw NoClassDefFoundError at loadLinks time → "No playable
    // source" (the source loads fine in CloudStream, which has Ktor). We pin 3.2.x,
    // NOT CloudStream's 3.5.0: 3.5.0 requires kotlin-stdlib 2.3.x and drags the whole
    // graph forward, which our pinned Kotlin 2.2.20 compiler can't read (broke the
    // vendored Aniyomi code). 3.2.x's stdlib floor is ≤2.2.x so there's no upward
    // pull — compile stays clean. The 4 io.ktor.http URL classes the plugins use are
    // stable across all 3.x, so the plugin (built vs 3.5.0) runs fine against 3.2.x.
    // runtimeOnly: only the dex-loaded plugin uses Ktor, never our own Kotlin.
    runtimeOnly("io.ktor:ktor-http:3.2.3")
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

    // ExoPlayer, powering both the fully-native TV player (TvPlayerActivity) and
    // the legacy Flutter platform-view TV player (ExoPlayerView). 1.7.1 is the
    // floor required by the prebuilt nextlib FFmpeg extension below; it's a stable
    // release CloudStream ships even newer (1.9.x), and — unlike the earlier
    // revert — the black screen it was blamed for is now known to be the Flutter
    // platform-view compositing, not the media3 version. The phone player
    // (media_kit/mpv) doesn't use media3 at all, so this never touches mobile.
    implementation("androidx.media3:media3-exoplayer:1.7.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.7.1")
    // DASH + SmoothStreaming so streams in those containers play (e.g. some
    // CloudStream movie sources like MovieBox). Without the DASH module,
    // DefaultMediaSourceFactory throws when it meets a .mpd stream.
    implementation("androidx.media3:media3-exoplayer-dash:1.7.1")
    implementation("androidx.media3:media3-exoplayer-smoothstreaming:1.7.1")
    implementation("androidx.media3:media3-ui:1.7.1")
    // Prebuilt FFmpeg software AUDIO decoders (Dolby AC3/E-AC3, DTS) — the exact
    // artifact CloudStream uses, straight off Maven Central (native .so bundled,
    // no source build). Version pairs with media3 1.7.1; nextlib 0.9.0 predates
    // the text-renderer crash later versions carry, so plain NextRenderersFactory
    // works (no Fixed* patch needed). Consumed ONLY by TvPlayerActivity, and only
    // when the user opts into software decoding (default off, like CloudStream —
    // whose own code disables it on TV by default "because of crashes"). Never
    // touches the phone player or the Flutter platform-view player.
    implementation("io.github.anilbeesetti:nextlib-media3ext:1.7.1-0.9.0")
}

// google-services.json is gitignored (see android/.gitignore). Dart already
// no-ops Analytics/FCM when Firebase.initializeApp() fails, so a missing file
// must not fail the Gradle build — same idea as falling back when
// key.properties is absent. Drop the real file at android/app/google-services.json
// (Firebase console → Project settings → Android app) to turn Firebase on.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}
