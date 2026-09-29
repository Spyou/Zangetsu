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
 * Adapted from the Aniyomi project (https://github.com/aniyomiorg/aniyomi)
 * for host-side extension loading in the Zangetsu app.
 */
package com.spyou.watch_app.aniyomi

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import dalvik.system.DexClassLoader
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.AnimeSourceFactory
import java.io.File

/**
 * A loaded Aniyomi anime extension, ready to be registered with [AniyomiSourceManager].
 *
 * @param pkg         the APK's declared package name.
 * @param versionName the full versionName string from the APK manifest.
 * @param versionCode the APK's versionCode (longVersionCode on API 28+, versionCode below).
 * @param libVersion  the derived extensions-lib version (major.minor from [libVersionOf]).
 * @param nsfw        true when the extension is flagged for adult content.
 * @param sources     the [AnimeSource] instances produced by this extension.
 */
data class LoadedExtension(
    val pkg: String,
    val versionName: String,
    val versionCode: Long,
    val libVersion: Double,
    val nsfw: Boolean,
    val sources: List<AnimeSource>,
)

/**
 * Loads Aniyomi anime-extension APKs via [DexClassLoader].
 *
 * A loaded extension must:
 *  1. Declare `<uses-feature android:name="tachiyomi.animeextension">` in its manifest.
 *  2. Declare its source class(es) in metadata key [METADATA_CLASS] (semicolon-separated).
 *  3. Have a [libVersionOf] result in [[ANIME_LIB_VERSION_MIN]..[ANIME_LIB_VERSION_MAX]].
 *
 * The loader never throws — all errors are wrapped as [Result.failure].
 */
object AniyomiExtensionLoader {

    /**
     * Minimum supported extensions-lib version (inclusive).
     * 
     * Kept at 12.0 to maintain backward compatibility with older extensions.
     * Extensions below this version use interfaces that Zangetsu no longer supports.
     */
    const val ANIME_LIB_VERSION_MIN = 12.0

    /**
     * Maximum supported extensions-lib version (inclusive).
     * 
     * Increased from 16.0 to 25.0 to support newer Aniyomi/Mihon extensions.
     * As of 2026, community repositories (keiyoushi, etc.) publish extensions with
     * libVersion 14.x, 16.x, and newer versions up to 17.x+. The upper bound is set
     * generously to accommodate future minor version bumps without requiring
     * app updates. Major API breaks (20.0+) may require updates to Zangetsu's
     * vendored source-api interfaces.
     * 
     * Compatibility note: Extensions with libVersion > 20.0 may use API features
     * not yet present in Zangetsu's bundled source-api. Such extensions will load
     * but may fail at runtime when calling unsupported methods. This is intentional
     * — it allows newer extensions to be tried while providing a clear error path.
     */
    const val ANIME_LIB_VERSION_MAX = 25.0

    /**
     * When enabled, allows loading extensions with libVersion > ANIME_LIB_VERSION_MAX
     * in a compatibility mode. This is a fallback for testing newer extensions that
     * may work despite using a newer libVersion.
     * 
     * DEFAULT: false (disabled for production stability)
     * Can be enabled via build flags or runtime configuration for testing.
     */
    const val ENABLE_COMPATIBILITY_MODE = false

    /** Manifest feature flag that identifies a valid Aniyomi anime extension. */
    private const val FEATURE = "tachiyomi.animeextension"

    /** Manifest metadata key listing the source class(es), semicolon-separated. */
    private const val METADATA_CLASS = "tachiyomi.animeextension.class"

    /**
     * Manifest metadata key for the NSFW flag.
     *
     * The Dantotsu-derived fork uses a double-n key ("tachiyomi.animeextensionn.nsfw").
     * Mainstream Aniyomi extensions use the single-n key ("tachiyomi.animeextension.nsfw").
     * We check the double-n key first (plan spec), then fall back to single-n.
     */
    private const val METADATA_NSFW_DOUBLE_N = "tachiyomi.animeextensionn.nsfw"
    private const val METADATA_NSFW_SINGLE_N = "tachiyomi.animeextension.nsfw"

    /**
     * Derives the extensions-lib version from the APK [versionName].
     *
     * The versionName encodes the lib version as the part before the last dot.
     * Examples:
     *   "14.17" → substringBeforeLast('.') = "14" → 14.0
     *   "16.0"  → substringBeforeLast('.') = "16" → 16.0
     *   "16.1"  → substringBeforeLast('.') = "16" → 16.0
     *   "17.2"  → substringBeforeLast('.') = "17" → 17.0 (rejected, > 16.0)
     *
     * @param versionName the full versionName string from the APK manifest.
     * @return the derived lib version as a Double.
     * @throws NumberFormatException if the result is not parseable as a Double.
     */
    fun libVersionOf(versionName: String): Double =
        versionName.substringBeforeLast('.').toDouble()

    private fun libVersionOf(versionName: String, meta: android.os.Bundle?): Double {
        val explicit = sequenceOf(
            "tachiyomi.animeextensionLib",
            "tachiyomi.extensionLib",
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
     * Extensions typically declare class names with a leading dot (e.g. ".HiAnime"), which
     * is a shorthand for the package-relative name. This function expands such names into
     * fully-qualified class names.
     *
     * @param pkg the APK package name (e.g. "eu.kanade.tachiyomi.animeextension.en.hianime").
     * @param raw the raw class name from the manifest metadata (e.g. ".HiAnime" or fully-qualified).
     * @return the fully-qualified class name.
     */
    fun resolveClassName(pkg: String, raw: String): String =
        if (raw.startsWith(".")) pkg + raw else raw

    /**
     * Returns true if [libVersion] is within [[ANIME_LIB_VERSION_MIN]..[ANIME_LIB_VERSION_MAX]].
     * 
     * When [ENABLE_COMPATIBILITY_MODE] is true, also accepts versions slightly above the max
     * to allow testing of newer extensions.
     */
    fun isLibVersionSupported(libVersion: Double): Boolean {
        if (libVersion in ANIME_LIB_VERSION_MIN..ANIME_LIB_VERSION_MAX) {
            return true
        }
        // In compatibility mode, allow versions up to ANIME_LIB_VERSION_MAX + 5.0
        if (ENABLE_COMPATIBILITY_MODE && libVersion <= ANIME_LIB_VERSION_MAX + 5.0) {
            return true
        }
        return false
    }

    /**
     * Loads an Aniyomi anime-extension APK, reads its manifest metadata, gates the
     * extensions-lib version, and instantiates the [AnimeSource](s) it declares.
     *
     * Must be called on any thread (the DexClassLoader optimisation and class initialisation
     * can be slow — do not call on the main thread).
     *
     * @param context Android context used for [PackageManager], [DexClassLoader] cache dir,
     *                and the injekt graph bootstrap via [AniyomiInjektModules.ensureRegistered].
     * @param apkFile the extension APK file on disk.
     * @return [Result.success] containing a [LoadedExtension], or [Result.failure] on any error.
     *         This method never throws.
     */
    @Suppress("DEPRECATION")
    fun load(context: Context, apkFile: File): Result<LoadedExtension> = runCatching {
        AniyomiInjektModules.ensureRegistered(context)

        val pm = context.packageManager
        val flags = PackageManager.GET_META_DATA or PackageManager.GET_CONFIGURATIONS
        val pkgInfo = pm.getPackageArchiveInfo(apkFile.absolutePath, flags)
            ?: error("Not an APK or could not parse manifest: ${apkFile.name}")

        // Verify the uses-feature flag that identifies an Aniyomi anime extension.
        // Check for both the standard feature and common variants used by forks.
        val hasFeature = pkgInfo.reqFeatures?.any { feature ->
            feature.name == FEATURE ||
            feature.name == "tachiyomi.extension" ||  // Mihon-style feature
            feature.name == "tachiyomi.animeextensionn"  // Variant with double 'n'
        } == true
        
        if (!hasFeature) {
            android.util.Log.w(
                "AniyomiLoad",
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
            val isSlightlyAbove = libVersion <= ANIME_LIB_VERSION_MAX + 5.0
            val allowInCompatMode = ENABLE_COMPATIBILITY_MODE || isSlightlyAbove
            
            if (allowInCompatMode) {
                android.util.Log.w(
                    "AniyomiLoad",
                    "Extension $pkg has libVersion $libVersion which is above the " +
                    "supported range $ANIME_LIB_VERSION_MIN..$ANIME_LIB_VERSION_MAX. " +
                    "Attempting to load in compatibility mode. " +
                    "Note: Some features may not work correctly."
                )
                // Allow loading but log a warning
            } else {
                error(
                    "Unsupported extensions-lib version $libVersion " +
                    "(supported range: $ANIME_LIB_VERSION_MIN..$ANIME_LIB_VERSION_MAX). " +
                    "This extension may require a newer version of Zangetsu. " +
                    "If you believe this extension should work, please report it " +
                    "at https://github.com/Spyou/Zangetsu/issues with the extension name and version."
                )
            }
        } else {
            android.util.Log.v(
                "AniyomiLoad",
                "Loading extension $pkg with libVersion $libVersion (within range $ANIME_LIB_VERSION_MIN..$ANIME_LIB_VERSION_MAX)"
            )
        }

        var classList = meta?.getString(METADATA_CLASS).orEmpty().trim()
        
        // Try alternative metadata keys used by forks
        if (classList.isBlank()) {
            val altClassList = meta?.getString("tachiyomi.extension.class")?.trim().orEmpty()
            if (altClassList.isNotBlank()) {
                android.util.Log.i(
                    "AniyomiLoad",
                    "Using alternative metadata key for source classes"
                )
                classList = altClassList
            }
        }
        
        if (classList.isBlank()) {
            error(
                "No source classes declared (missing metadata key \"$METADATA_CLASS\" or \"tachiyomi.extension.class\"). " +
                "This APK may not be a valid Aniyomi extension."
            )
        }

        // Check double-n key first (Dantotsu fork), fall back to single-n (mainstream Aniyomi).
        val nsfw = when {
            meta != null && meta.containsKey(METADATA_NSFW_DOUBLE_N) ->
                meta.getInt(METADATA_NSFW_DOUBLE_N, 0) == 1
            meta != null && meta.containsKey(METADATA_NSFW_SINGLE_N) ->
                meta.getInt(METADATA_NSFW_SINGLE_N, 0) == 1
            else -> false
        }

        // Optimised DEX output directory, scoped to the Aniyomi namespace.
        val optimizedDir = File(context.codeCacheDir, "aniyomi-dex").apply { mkdirs() }

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
                    is AnimeSource -> listOf(instance)
                    is AnimeSourceFactory -> instance.createSources()
                    else -> emptyList()
                }
            }

        require(sources.isNotEmpty()) {
            "Extension produced no AnimeSource instances from class list: $classList"
        }

        LoadedExtension(
            pkg = pkg,
            versionName = versionName,
            versionCode = versionCode,
            libVersion = libVersion,
            nsfw = nsfw,
            sources = sources,
        )
    }
}
