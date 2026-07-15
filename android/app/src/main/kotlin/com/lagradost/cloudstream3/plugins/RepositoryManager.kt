package com.lagradost.cloudstream3.plugins

import com.lagradost.cloudstream3.ui.settings.extensions.RepositoryData
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.URL

/**
 * App-internal CloudStream singleton, NOT in the bundled `library` artifact.
 * In the real CloudStream app it persists the user's repositories to shared
 * prefs. We vendor a compatible shape so "mega repo" plugins (which call
 * [addRepository] in their `load()` to batch-add repositories) resolve AND
 * actually take effect — [onRepoAdded] bridges each added repo back to the
 * Dart side, which routes it through the real [CloudStreamManager.addRepo].
 *
 * Purely additive: no existing CloudStream source references this class, so
 * normal install/playback is unaffected.
 */
object RepositoryManager {

    /** Set by MainActivity: forwards each newly added repo URL to Dart. */
    @Volatile
    var onRepoAdded: ((String) -> Unit)? = null

    private val lock = Any()
    private val collected = mutableListOf<RepositoryData>()

    /** Repos already registered this session (a plugin uses this to dedupe). */
    fun getRepositories(): Array<RepositoryData> = synchronized(lock) {
        collected.toTypedArray()
    }

    /** Called by a mega-repo plugin for each repository it wants to add. */
    suspend fun addRepository(repository: RepositoryData) {
        val isNew = synchronized(lock) {
            if (collected.none { it.url == repository.url }) {
                collected.add(repository)
                true
            } else {
                false
            }
        }
        if (isNew) onRepoAdded?.invoke(repository.url)
    }

    /**
     * Fetch + parse a repo manifest so the plugin can read its name/lists.
     * Network runs off the main thread; any failure degrades to a minimal
     * manifest so the plugin still proceeds to [addRepository].
     */
    suspend fun parseRepository(url: String): Repository? = withContext(Dispatchers.IO) {
        try {
            val o = JSONObject(fetch(url))
            val lists = o.optJSONArray("pluginLists") ?: JSONArray()
            Repository(
                name = o.optString("name").ifEmpty { url },
                description = o.optString("description").ifEmpty { null },
                manifestVersion = o.optInt("manifestVersion", 1),
                pluginLists = (0 until lists.length())
                    .mapNotNull { lists.optString(it).ifEmpty { null } },
                iconUrl = o.optString("iconUrl").ifEmpty { null },
            )
        } catch (_: Exception) {
            Repository(name = url)
        }
    }

    private fun fetch(u: String): String {
        val conn = URL(u).openConnection()
        conn.connectTimeout = 15000
        conn.readTimeout = 20000
        conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Android) Zangetsu")
        return conn.getInputStream().bufferedReader().use { it.readText() }
    }
}
