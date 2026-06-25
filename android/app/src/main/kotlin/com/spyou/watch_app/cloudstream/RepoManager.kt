package com.spyou.watch_app.cloudstream

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URL

/** One installable CloudStream plugin as advertised by a repo's plugin list. */
data class CsPlugin(
    val internalName: String,
    val name: String,
    val url: String,          // the .cs3 download URL
    val version: Int,
    val language: String?,
    val tvTypes: List<String>,
    val iconUrl: String?,
    val repoUrl: String,
) {
    /** JSON-able view for the Flutter bridge (the repo catalog). */
    fun toMap(): Map<String, Any?> = mapOf(
        "internalName" to internalName,
        "name" to name,
        "url" to url,
        "version" to version,
        "language" to language,
        "tvTypes" to tvTypes,
        "iconUrl" to iconUrl,
    )
}

/**
 * Downloads a CloudStream `repo.json`, walks its `pluginLists`, and caches the
 * `.cs3` files under `filesDir/cs3/`. Plain `java.net` HTTP — no extra deps.
 */
class RepoManager(private val context: Context) {

    private val cs3Dir: File by lazy { File(context.filesDir, "cs3").apply { mkdirs() } }

    private fun fetch(url: String): String {
        val conn = URL(url).openConnection()
        conn.connectTimeout = 15000
        conn.readTimeout = 20000
        conn.setRequestProperty("User-Agent", UA)
        return conn.getInputStream().bufferedReader().use { it.readText() }
    }

    /** repo.json → `pluginLists[]` (each a URL to a JSON array of plugin objects). */
    fun listPlugins(repoUrl: String): List<CsPlugin> = loadRepo(repoUrl).second

    /**
     * Fetch `repo.json` once and return its top-level `name` (falling back to the
     * URL host) paired with the full advertised plugin list. Combined so callers
     * that need both don't re-fetch repo.json.
     */
    fun loadRepo(repoUrl: String): Pair<String, List<CsPlugin>> {
        val out = mutableListOf<CsPlugin>()
        val repo = JSONObject(fetch(repoUrl))
        val name = repo.optString("name").ifEmpty { hostOf(repoUrl) }
        val lists = repo.optJSONArray("pluginLists") ?: JSONArray()
        for (i in 0 until lists.length()) {
            val listUrl = lists.optString(i).ifEmpty { continue }
            try {
                val arr = JSONArray(fetch(listUrl))
                for (j in 0 until arr.length()) {
                    val p = arr.optJSONObject(j) ?: continue
                    val cs3 = p.optString("url")
                    if (cs3.isEmpty()) continue
                    out.add(
                        CsPlugin(
                            internalName = p.optString("internalName", p.optString("name")),
                            name = p.optString("name", p.optString("internalName")),
                            url = cs3,
                            version = p.optInt("version", 1),
                            language = p.optString("language").ifEmpty { null },
                            tvTypes = p.optJSONArray("tvTypes")?.let { t ->
                                (0 until t.length()).map { t.optString(it) }
                            } ?: emptyList(),
                            iconUrl = p.optString("iconUrl").ifEmpty { null },
                            repoUrl = repoUrl,
                        ),
                    )
                }
            } catch (_: Exception) { /* skip a bad list */ }
        }
        return name to out
    }

    /** Best-effort host of a repo URL, used as a display name when repo.json has none. */
    private fun hostOf(repoUrl: String): String =
        try { URL(repoUrl).host?.ifEmpty { null } ?: repoUrl } catch (_: Exception) { repoUrl }

    /** Download (or reuse) a plugin's `.cs3` into the cache and return the file. */
    fun download(plugin: CsPlugin): File =
        download(plugin.url, plugin.internalName, plugin.version)

    /**
     * Download (or reuse) a single `.cs3` by its raw fields — used to install one
     * plugin on demand (the catalog lives in Dart, so installs pass the fields).
     */
    fun download(cs3Url: String, internalName: String, version: Int): File {
        // Tag the cache file by its repo so two repos that ship a plugin with the
        // SAME internalName don't share one `.cs3` (which made installing one
        // "install" the other and uninstalling one delete both).
        val f = File(cs3Dir, "$internalName@$version@${repoTag(cs3Url)}.cs3")
        if (f.exists() && f.length() > 0) return f
        val conn = URL(cs3Url).openConnection()
        conn.connectTimeout = 15000
        conn.readTimeout = 30000
        conn.setRequestProperty("User-Agent", UA)
        conn.getInputStream().use { input -> f.outputStream().use { input.copyTo(it) } }
        return f
    }

    fun cachedFiles(): List<File> =
        cs3Dir.listFiles()?.filter { it.isFile && it.extension == "cs3" } ?: emptyList()

    companion object {
        const val UA = "Mozilla/5.0 (Android) Zangetsu"

        /** A short, stable per-repo tag derived from the plugin's `.cs3`
         *  directory (everything before the file name — same for every plugin in
         *  a repo and across its version bumps, distinct between repos). Two
         *  repos shipping the same internalName therefore cache to different
         *  files and install/uninstall independently. */
        fun repoTag(cs3Url: String): String =
            Integer.toHexString(cs3Url.substringBeforeLast('/').lowercase().hashCode())
    }
}
