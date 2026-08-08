/*
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
 * Adapted from the Mihon project (https://github.com/mihonapp/mihon), file
 * app/src/main/java/eu/kanade/tachiyomi/AppInfo.kt at commit
 * 21c63579678be4cfe19ba0982d8a158fe300f278 — the same pin the rest of the
 * vendored tree came from.
 */
package eu.kanade.tachiyomi

import android.app.Application
import android.content.pm.PackageInfo
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

/**
 * Used by extensions.
 *
 * This is a **host-provided** class: extension APKs are compiled against it but
 * never ship it, so it has to be resolvable through the parent classloader we
 * hand to `DexClassLoader` (see `MihonExtensionLoader`). Without it, MangaDex —
 * and every other extension that builds a User-Agent in `headersBuilder()` —
 * dies with `NoClassDefFoundError: Leu/kanade/tachiyomi/AppInfo;` the moment
 * anything touches `HttpSource.headers`.
 *
 * The signatures below are load-bearing: extensions link against them by name
 * and descriptor, so they must stay byte-for-byte compatible with upstream's.
 * Two bodies had to be adapted (both noted at the method):
 *
 *  1. The version pair is read off our own installed package rather than a
 *     `BuildConfig` — we report Zangetsu's real version either way.
 *  2. `getSupportedImageMimeTypes()` is a literal list, because the
 *     `ImageUtil.ImageType` enum upstream derives it from isn't vendored.
 */
@Suppress("UNUSED")
object AppInfo {

    /**
     * Our own manifest entry, or null if it can't be read.
     *
     * ADAPTED: upstream reads Mihon's generated `BuildConfig`. Ours isn't
     * generated — AGP 8 turns the `buildConfig` feature off by default and
     * nothing else in the app wanted it, so `com.spyou.watch_app.BuildConfig`
     * doesn't exist and enabling it is a build-file change this fix doesn't
     * need. The same two numbers are on the installed [PackageInfo], and the
     * [Application] is already in the Injekt graph that
     * `AniyomiInjektModules.ensureRegistered` stands up before any extension is
     * DEX-loaded — so by the time an extension can call this, it resolves.
     *
     * Lazy, so nothing touches Injekt at class-init time; null-tolerant, so a
     * caller that somehow arrives first gets a bland default instead of an
     * exception thrown back into extension code.
     */
    private val packageInfo: PackageInfo? by lazy {
        runCatching {
            val app = Injekt.get<Application>()
            app.packageManager.getPackageInfo(app.packageName, 0)
        }.getOrNull()
    }

    /**
     * Version code of the host application. May be useful for sharing as User-Agent information.
     * Note that this value differs between forks so logic should not rely on it.
     *
     * @since extension-lib 1.3
     */
    @Suppress("DEPRECATION") // longVersionCode's low 32 bits are exactly our versionCode
    fun getVersionCode(): Int = packageInfo?.versionCode ?: 0

    /**
     * Version name of the host application. May be useful for sharing as User-Agent information.
     * Note that this value differs between forks so logic should not rely on it.
     *
     * @since extension-lib 1.3
     */
    fun getVersionName(): String = packageInfo?.versionName ?: ""

    /**
     * A list of supported image MIME types by the reader.
     * @since extension-lib 1.5
     *
     * ADAPTED: upstream returns `ImageUtil.ImageType.entries.map { it.mime }`.
     * We don't vendor `ImageUtil`, and more to the point our reader isn't
     * Mihon's — `MangaReaderScreen` renders every page through
     * `CachedNetworkImage`, i.e. Flutter's `dart:ui` codec, which decodes JPEG,
     * PNG, GIF and WebP and nothing more. A source that asks this question uses
     * the answer to pick what it serves, so listing a format we can't decode
     * (JPEG XL, HEIF, AVIF) would hand the reader pages it can only render as a
     * broken-image icon. Only claim what we can actually draw.
     */
    fun getSupportedImageMimeTypes(): List<String> = listOf(
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp",
    )
}
