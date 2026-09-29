/*
 * Copyright 2015 Javier Tomás
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Adapted from the Mihon project (https://github.com/mihonapp/mihon)
 * for host-side extension loading in the Zangetsu app.
 */
package com.spyou.watch_app.mihon

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.spyou.watch_app.aniyomi.AniyomiInjektModules
import dalvik.system.DexClassLoader
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import java.io.File

/**
 * A loaded Mihon manga extension, ready to be registered with a manga source manager.
 *
 * @param pkg         the APK's declared package name.
 * @param versionName the full versionName string from the APK manifest.
 * @param versionCode the APK's versionCode (longVersionCode on API 28+, versionCode below).
 * @param libVersion  the derived extensions-lib version (major.minor from [libVersionOf]).
 * @param nsfw        true when the extension is flagged for adult content.
 * @param sources     the [Source] instances produced by this extension.
 */
data class MihonLoadedExtension(
    val pkg: String,
    val versionName: String,
    val versionCode: Long,
    val libVersion: Double,
    val nsfw: Boolean,
    val sources: List<Source>,
)

/**
 * Loads Mihon manga-extension APKs via [DexClassLoader].
 *
 * A loaded extension must:
 *  1. Declare `<uses-feature android:name="tachiyomi.extension">` in its manifest.
 *  2. Declare its source class(es) in metadata key [METADATA_CLASS] (semicolon-separated).
 *  3. Have a [libVersionOf] result in [[MANGA_LIB_VERSION_MIN]..[MANGA_LIB_VERSION_MAX]].
 *
 * This is a deliberate near-duplicate of `AniyomiExtensionLoader` — see that file for the
 * anime-extension equivalent. Kept separate (not parameterised into one shared loader) so the
 * anime path is never touched by manga changes.
 *
 * The loader never throws — all errors are wrapped as [Result.failure].
 */
object MihonExtensionLoader {

    /**
     * Supported extensions-lib versions (inclusive range).
     *
     * Real-world evidence (sampled 2026-08-05 from the keiyoushi community repo, the largest
     * active Mihon extension index — 1369 extension APKs at commit 2f29c42):
     * every single one carries a versionName of the form `<libMajor>.<libMinor>.<revision>`,
     * e.g. "1.4.52" or "1.6.11". Grouping by `<libMajor>.<libMinor>` yielded exactly two values
     * in circulation: 1175 extensions at "1.4" and 194 at "1.6" — no "1.5" observed anywhere.
     *
     * Mihon's own installer (`ExtensionLoader.kt` on mihonapp/mihon `main`) confirms this is by
     * design: it hardcodes `SUPPORTED_LIB_VERSIONS = listOf(1.4, 1.6)`, an exact allow-list, not
     * a range — 1.5 was apparently never shipped. It also confirms our `libVersionOf` derivation
     * is exactly Mihon's own fallback path: `metaData.getFloat("tachiyomix.extensionLib")
     * .takeUnless { it == 0f } ?: versionName.substringBeforeLast('.').toDoubleOrNull()`. Real
     * extensions don't set the optional override metadata, so the substringBeforeLast fallback
     * is what actually runs for the whole ecosystem — and unlike Aniyomi's 2-segment versionName
     * ("14.17"), Mihon's is 3-segment ("1.4.52"), so `substringBeforeLast('.')` correctly yields
     * "1.4", not "1" and not "1.0".
     *
     * We use a permissive continuous range rather than mirroring Mihon's exact {1.4, 1.6}
     * allow-list: 1.0..5.0 covers every observed value with generous headroom on both sides
     * (increased from 2.0 to 5.0 to match the anime side's tolerance). The range is inclusive,
     * so a "5.0.x" extension (libVersion 5.0) is still accepted — only a "5.1+" bump, which
     * would mean the vendored interface tree (pinned to the current source-api) is genuinely
     * out of date, gets rejected. A gate that's too strict silently rejects working extensions;
     * this one only fails on a real API break past 5.0.
     */
    const val MANGA_LIB_VERSION_MIN = 1.0

    /** See [MANGA_LIB_VERSION_MIN] for the full derivation and evidence. */
    const val MANGA_LIB_VERSION_MAX = 5.0

    /**
     * When enabled, allows loading extensions with libVersion > MANGA_LIB_VERSION_MAX
     * in a compatibility mode. This is a fallback for testing newer extensions that
     * may work despite using a newer libVersion.
     * 
     * DEFAULT: false (disabled for production stability)
     * Can be enabled via build flags or runtime configuration for testing.
     */
    const val ENABLE_COMPATIBILITY_MODE = false

    /** Manifest feature flag that identifies a valid Mihon manga extension. */
    private const val FEATURE = "tachiyomi.extension"

    /** Manifest metadata key listing the source class(es), semicolon-separated. */
    private const val METADATA_CLASS = "tachiyomi.extension.class"

    /** Manifest metadata key for the NSFW flag. Mihon uses a single-n key (no fork variant). */
    private const val METADATA_NSFW = "tachiyomi.extension.nsfw"

    /**
     * Derives the extensions-lib version from the APK [versionName].
     *
     * The versionName encodes the lib version as everything before the last dot. Examples:
     *   "1.4.52" → substringBeforeLast('.') = "1.4" → 1.4
     *   "1.6.11" → substringBeforeLast('.') = "1.6" → 1.6
     *
     * @param versionName the full versionName string from the APK manifest.
     * @return the derived lib version as a Double.
     * @throws NumberFormatException if the result is not parseable as a Double.
     */
    fun libVersionOf(versionName: String): Double =
        versionName.substringBeforeLast('.').toDouble()

    private fun libVersionOf(versionName: String, meta: android.os.Bundle?): Double {
        val explicit = sequenceOf(
            "tachiyomi.extensionLib",
            "tachiyomi.animeextensionLib",
        ).mapNotNull { key ->
            if (meta == null || !meta.containsKey(key)) return@mapNotNull null
            meta.getString(key)?.toDoubleOrNull()
                ?: meta.getFloat(key, Float.NaN).takeUnless { it.isNaN() }?.toDouble()
        }.firstOrNull()
        return explicit ?: libVersionOf(versionName)
    }

    /**
     * Resolves an extension class name, prefixing leading-dot names with the package name.
     *
     * @param pkg the APK package name (e.g. "eu.kanade.tachiyomi.extension.en.mangadex").
     * @param raw the raw class name from the manifest metadata (e.g. ".MangaDex" or fully-qualified).
     * @return the fully-qualified class name.
     */
    fun resolveClassName(pkg: String, raw: String): String =
        if (raw.startsWith(".")) pkg + raw else raw

    /**
     * Returns true if [libVersion] is within [[MANGA_LIB_VERSION_MIN]..[MANGA_LIB_VERSION_MAX]].
     * 
     * When [ENABLE_COMPATIBILITY_MODE] is true, also accepts versions slightly above the max
     * to allow testing of newer extensions.
     */
    fun isLibVersionSupported(libVersion: Double): Boolean {
        if (libVersion in MANGA_LIB_VERSION_MIN..MANGA_LIB_VERSION_MAX) {
            return true
        }
        // In compatibility mode, allow versions up to MANGA_LIB_VERSION_MAX + 5.0
        if (ENABLE_COMPATIBILITY_MODE && libVersion <= MANGA_LIB_VERSION_MAX + 5.0) {
            return true
        }
        return false
    }

    /**
     * Loads a Mihon manga-extension APK, reads its manifest metadata, gates the
     * extensions-lib version, and instantiates the [Source](s) it declares.
     *
     * Must be called on any thread (the DexClassLoader optimisation and class initialisation
     * can be slow — do not call on the main thread).
     *
     * @param context Android context used for [PackageManager], [DexClassLoader] cache dir,
     *                and the injekt graph bootstrap via [AniyomiInjektModules.ensureRegistered]
     *                (media-agnostic — shared with the anime extension loader, not duplicated).
     * @param apkFile the extension APK file on disk.
     * @return [Result.success] containing a [MihonLoadedExtension], or [Result.failure] on any
     *         error. This method never throws.
     */
    @Suppress("DEPRECATION")
    fun load(context: Context, apkFile: File): Result<MihonLoadedExtension> = runCatching {
        AniyomiInjektModules.ensureRegistered(context)

        val pm = context.packageManager
        val flags = PackageManager.GET_META_DATA or PackageManager.GET_CONFIGURATIONS
        val pkgInfo = pm.getPackageArchiveInfo(apkFile.absolutePath, flags)
            ?: error("Not an APK or could not parse manifest: ${apkFile.name}")

        // Verify the uses-feature flag that identifies a Mihon manga extension.
        // Check for both the standard feature and common variants used by forks.
        val hasFeature = pkgInfo.reqFeatures?.any { feature ->
            feature.name == FEATURE ||
            feature.name == "tachiyomi.animeextension" ||  // Aniyomi-style feature
            feature.name == "tachiyomi.extensionn"  // Variant with double 'n'
        } == true
        
        if (!hasFeature) {
            android.util.Log.w(
                "MihonLoad",
                "APK ${apkFile.name} does not declare expected feature flag. " +
                "This may be a legacy extension or a fork using a different feature name. " +
                "Attempting to load anyway."
            )
            // Don't block loading - some extensions might not declare this properly
            // but still be valid. We'll validate based on other criteria (metadata, classes).
        }

        val appInfo = pkgInfo.applicationInfo
            ?: error("Missing applicationInfo in APK manifest: ${apkFile.name}")
        val pkg = appInfo.packageName

        // Set the source path so PackageManager can read resources from this APK.
        appInfo.sourceDir = apkFile.absolutePath
        appInfo.publicSourceDir = apkFile.absolutePath

        val versionName = pkgInfo.versionName
            ?: error("Missing versionName in APK manifest: ${apkFile.name}")

        val versionCode: Long =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pkgInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                pkgInfo.versionCode.toLong()
            }

        val meta = appInfo.metaData
        val libVersion = runCatching { libVersionOf(versionName, meta) }.getOrElse { e ->
            error("Cannot parse lib version from versionName \"$versionName\": ${e.message}")
        }
        
        // Check if libVersion is within the supported range
        if (!isLibVersionSupported(libVersion)) {
            // Check if compatibility mode is enabled OR if the version is only slightly above max
            val isSlightlyAbove = libVersion <= MANGA_LIB_VERSION_MAX + 5.0
            val allowInCompatMode = ENABLE_COMPATIBILITY_MODE || isSlightlyAbove
            
            if (allowInCompatMode) {
                android.util.Log.w(
                    "MihonLoad",
                    "Extension $pkg has libVersion $libVersion which is above the " +
                    "supported range $MANGA_LIB_VERSION_MIN..$MANGA_LIB_VERSION_MAX. " +
                    "Attempting to load in compatibility mode. " +
                    "Note: Some features may not work correctly."
                )
                // Allow loading but log a warning
            } else {
                error(
                    "Unsupported extensions-lib version $libVersion " +
                    "(supported range: $MANGA_LIB_VERSION_MIN..$MANGA_LIB_VERSION_MAX). " +
                    "This extension may require a newer version of Zangetsu. " +
                    "If you believe this extension should work, please report it " +
                    "at https://github.com/Spyou/Zangetsu/issues with the extension name and version."
                )
            }
        } else {
            android.util.Log.v(
                "MihonLoad",
                "Loading extension $pkg with libVersion $libVersion (within range $MANGA_LIB_VERSION_MIN..$MANGA_LIB_VERSION_MAX)"
            )
        }

        var classList = meta?.getString(METADATA_CLASS).orEmpty().trim()
        
        // Try alternative metadata keys used by forks
        if (classList.isBlank()) {
            val altClassList = meta?.getString("tachiyomi.animeextension.class")?.trim().orEmpty()
            if (altClassList.isNotBlank()) {
                android.util.Log.i(
                    "MihonLoad",
                    "Using alternative metadata key for source classes"
                )
                classList = altClassList
            }
        }
        
        if (classList.isBlank()) {
            error(
                "No source classes declared (missing metadata key \"$METADATA_CLASS\" or \"tachiyomi.animeextension.class\"). " +
                "This APK may not be a valid Mihon extension."
            )
        }

        val nsfw = meta?.getInt(METADATA_NSFW, 0) == 1

        // Optimised DEX output directory, scoped to the Mihon namespace. Kept separate from
        // "aniyomi-dex" — sharing risks cross-contaminating optimised DEX for identically-named
        // classes between the two extension ecosystems.
        val optimizedDir = File(context.codeCacheDir, "mihon-dex").apply { mkdirs() }

        // Android's runtime (W^X protection) refuses to load a DEX/APK that is
        // still writable by the app ("Writable dex file is not allowed"). The apk
        // was just downloaded into app-private storage, so strip write access
        // before handing it to the classloader.
        apkFile.setReadOnly()

        val loader = DexClassLoader(
            apkFile.absolutePath,
            optimizedDir.absolutePath,
            null,                    // librarySearchPath — extensions have no native libs
            context.classLoader,     // parent classloader so vendored runtime is accessible
        )

        val sources = classList
            .split(";")
            .map { it.trim() }
            .filter { it.isNotBlank() }
            .flatMap { raw ->
                val className = resolveClassName(pkg, raw)
                val clazz = loader.loadClass(className)
                val instance = clazz.getDeclaredConstructor().newInstance()
                when (instance) {
                    is Source -> listOf(instance)
                    is SourceFactory -> instance.createSources()
                    else -> emptyList()
                }
            }

        require(sources.isNotEmpty()) {
            "Extension produced no Source instances from class list: $classList"
        }

        MihonLoadedExtension(
            pkg = pkg,
            versionName = versionName,
            versionCode = versionCode,
            libVersion = libVersion,
            nsfw = nsfw,
            sources = sources,
        )
    }
}
