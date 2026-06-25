package com.lagradost.cloudstream3.utils

import android.content.Context
import android.content.SharedPreferences
import com.fasterxml.jackson.databind.json.JsonMapper
import com.fasterxml.jackson.module.kotlin.kotlinModule
import com.lagradost.cloudstream3.CloudStreamApp

/**
 * Clean-room stand-in for CloudStream's app-module `DataStore` (the key/value
 * settings store backed by SharedPreferences + a Jackson mapper).
 *
 * `.cs3` plugins read/write their own settings (e.g. a Stremio addon list, a
 * preferred server) through this class. Older plugins INLINED CloudStream's
 * `getKey`/`setKey`, so their bytecode only needs `DataStore.getMapper()` +
 * `DataStore.getSharedPrefs(context)` — which is all the original stand-in
 * exposed. Newer plugins instead call the NON-inline `Context.setKey` /
 * `Context.getKey` EXTENSION functions; without those a save throws
 * `NoSuchMethodError`, is swallowed, and the setting silently never persists
 * (and the settings sheet, which reads on open, fails to show). So we now mirror
 * the real DataStore's public surface — the Context extensions, folder helpers
 * and remove/contains — all backed by the same prefs + mapper, so old (inlined)
 * and new (extension) plugins both persist consistently.
 *
 * Storage is self-consistent within this app (every read and write goes through
 * these methods + this prefs file), which is all that matters here — we don't
 * need byte-compat with the real CloudStream app's prefs file or serializer.
 */
object DataStore {
    private const val PREFS = "cs3_datastore"

    /** Jackson mapper the plugins' inlined getKey uses to (de)serialize values. */
    val mapper: JsonMapper = JsonMapper.builder()
        .addModule(kotlinModule())
        .build()

    // JVM signature getSharedPrefs(Context) — exactly what both plugins'
    // (inlined) bytecode and our own callers reference. A `Context.getSharedPrefs()`
    // extension would compile to this same signature, so we keep just this one.
    fun getSharedPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Folder-prefixed key, identical to CloudStream's "folder/path". */
    fun getFolderName(folder: String, path: String): String = "$folder/$path"

    // ── legacy static variants (kept for any plugin that references them) ────────
    fun <T> setKey(path: String, value: T) {
        val ctx = CloudStreamApp.getContext() ?: return
        try {
            getSharedPrefs(ctx).edit()
                .putString(path, mapper.writeValueAsString(value))
                .apply()
        } catch (_: Exception) {
        }
    }

    fun <T> getKey(path: String, valueType: Class<T>): T? {
        val ctx = CloudStreamApp.getContext() ?: return null
        val json = getSharedPrefs(ctx).getString(path, null) ?: return null
        return try {
            mapper.readValue(json, valueType)
        } catch (_: Exception) {
            null
        }
    }

    // ── Context extensions the newer plugins (e.g. StremioX) actually call ───────
    fun <T> Context.setKey(path: String, value: T) {
        try {
            getSharedPrefs(this).edit()
                .putString(path, mapper.writeValueAsString(value))
                .apply()
        } catch (_: Exception) {
        }
    }

    fun <T> Context.setKey(folder: String, path: String, value: T) =
        setKey(getFolderName(folder, path), value)

    fun <T : Any> Context.getKey(path: String, valueType: Class<T>): T? {
        val json = getSharedPrefs(this).getString(path, null) ?: return null
        return try {
            mapper.readValue(json, valueType)
        } catch (_: Exception) {
            null
        }
    }

    fun <T : Any> Context.getKey(folder: String, path: String, valueType: Class<T>): T? =
        getKey(getFolderName(folder, path), valueType)

    fun Context.getKeys(folder: String): List<String> {
        val fixed = folder.trimEnd('/') + "/"
        return try {
            getSharedPrefs(this).all.keys.filter { it.startsWith(fixed) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun Context.containsKey(path: String): Boolean =
        try { getSharedPrefs(this).contains(path) } catch (_: Exception) { false }

    fun Context.containsKey(folder: String, path: String): Boolean =
        containsKey(getFolderName(folder, path))

    fun Context.removeKey(path: String) {
        try {
            val prefs = getSharedPrefs(this)
            if (prefs.contains(path)) prefs.edit().remove(path).apply()
        } catch (_: Exception) {
        }
    }

    fun Context.removeKey(folder: String, path: String) =
        removeKey(getFolderName(folder, path))

    fun Context.removeKeys(folder: String): Int {
        return try {
            val keys = getKeys("$folder/")
            val editor = getSharedPrefs(this).edit()
            keys.forEach { editor.remove(it) }
            editor.apply()
            keys.size
        } catch (_: Exception) {
            0
        }
    }
}
