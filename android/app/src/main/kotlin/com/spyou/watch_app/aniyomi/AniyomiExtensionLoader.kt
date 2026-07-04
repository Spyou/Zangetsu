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
import dalvik.system.DexClassLoader
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.AnimeSourceFactory
import java.io.File

/**
 * A loaded Aniyomi anime extension, ready to be registered with [AniyomiSourceManager].
 *
 * @param pkg         the APK's declared package name.
 * @param versionName the full versionName string from the APK manifest.
 * @param libVersion  the derived extensions-lib version (major.minor from [libVersionOf]).
 * @param nsfw        true when the extension is flagged for adult content.
 * @param sources     the [AnimeSource] instances produced by this extension.
 */
data class LoadedExtension(
    val pkg: String,
    val versionName: String,
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

    /** Minimum supported extensions-lib version (inclusive). */
    const val ANIME_LIB_VERSION_MIN = 12.0

    /** Maximum supported extensions-lib version (inclusive). */
    const val ANIME_LIB_VERSION_MAX = 16.0

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
     */
    fun isLibVersionSupported(libVersion: Double): Boolean =
        libVersion in ANIME_LIB_VERSION_MIN..ANIME_LIB_VERSION_MAX

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
        val hasFeature = pkgInfo.reqFeatures?.any { it.name == FEATURE } == true
        require(hasFeature) {
            "Not an Aniyomi anime extension (missing <uses-feature name=\"$FEATURE\">)"
        }

        val appInfo = pkgInfo.applicationInfo
            ?: error("Missing applicationInfo in APK manifest: ${apkFile.name}")

        // Set the source path so PackageManager can read resources from this APK.
        appInfo.sourceDir = apkFile.absolutePath
        appInfo.publicSourceDir = apkFile.absolutePath

        val versionName = pkgInfo.versionName
            ?: error("Missing versionName in APK manifest: ${apkFile.name}")

        val libVersion = runCatching { libVersionOf(versionName) }.getOrElse { e ->
            error("Cannot parse lib version from versionName \"$versionName\": ${e.message}")
        }
        require(isLibVersionSupported(libVersion)) {
            "Unsupported extensions-lib version $libVersion " +
                "(supported range: $ANIME_LIB_VERSION_MIN..$ANIME_LIB_VERSION_MAX)"
        }

        val meta = appInfo.metaData
        val classList = meta?.getString(METADATA_CLASS).orEmpty().trim()
        require(classList.isNotBlank()) {
            "No source classes declared (missing metadata key \"$METADATA_CLASS\")"
        }

        // Check double-n key first (Dantotsu fork), fall back to single-n (mainstream Aniyomi).
        val nsfw = when {
            meta != null && meta.containsKey(METADATA_NSFW_DOUBLE_N) ->
                meta.getInt(METADATA_NSFW_DOUBLE_N, 0) == 1
            meta != null && meta.containsKey(METADATA_NSFW_SINGLE_N) ->
                meta.getInt(METADATA_NSFW_SINGLE_N, 0) == 1
            else -> false
        }

        val pkg = appInfo.packageName

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
            libVersion = libVersion,
            nsfw = nsfw,
            sources = sources,
        )
    }
}
