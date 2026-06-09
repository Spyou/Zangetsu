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
 * Newer `.cs3` plugins read/write settings via CloudStream's inlined
 * `getKey`/`setKey`, whose bytecode references `DataStore.getMapper()` and
 * `DataStore.getSharedPrefs(context)`. Jackson is already on the classpath (a
 * transitive dep of the bundled CloudStream library), so we only need to expose
 * this small surface. Without it, settings-reading plugins (e.g. AnimePahe)
 * throw `NoClassDefFoundError` on load and never install.
 */
object DataStore {
    private const val PREFS = "cs3_datastore"

    /** Jackson mapper the plugins' inlined getKey uses to (de)serialize values. */
    val mapper: JsonMapper = JsonMapper.builder()
        .addModule(kotlinModule())
        .build()

    fun getSharedPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

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
}
