package com.spyou.watch_app

import android.content.Context
import androidx.preference.CheckBoxPreference
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.MultiSelectListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceManager
import androidx.preference.PreferenceScreen
import androidx.preference.SwitchPreferenceCompat

/**
 * Turns an extension's own `PreferenceScreen` into plain data Flutter can draw,
 * and applies a change back through it.
 *
 * Aniyomi and Mihon sources declare their settings the Android way, by filling
 * a [PreferenceScreen] in `setupPreferenceScreen`. That is what
 * `AniyomiSettingsActivity` / `MihonSettingsActivity` show. Nothing about those
 * objects is UI though: they are a typed list, so the app can render them
 * itself and stop sending the user out to a second, differently themed screen.
 *
 * Both bridges build the screen the same way, so the walking and the writing
 * live here rather than twice.
 */
object SourcePrefsCodec {

    const val TYPE_SWITCH = "switch"
    const val TYPE_CHECKBOX = "checkbox"
    const val TYPE_LIST = "list"
    const val TYPE_MULTI = "multi"
    const val TYPE_TEXT = "text"

    /** Anything we cannot draw faithfully. The caller falls back whole-page. */
    const val TYPE_UNKNOWN = "unknown"

    /**
     * A fresh screen for [sourceId], built by [setup].
     *
     * Rebuilt on every call rather than cached: the source constructs new
     * [Preference] objects — and, crucially, new change listeners — each time,
     * and a listener bound to a stale screen would write into an object nothing
     * reads. Construction is cheap; it is object graph building, no I/O.
     *
     * The store name matches what the extension reads at runtime, so a value
     * written here is the value it sees.
     */
    fun buildScreen(
        context: Context,
        sourceId: Long,
        setup: (PreferenceScreen) -> Unit,
    ): PreferenceScreen {
        val manager = PreferenceManager(context)
        manager.sharedPreferencesName = "source_$sourceId"
        val screen = manager.createPreferenceScreen(context)
        setup(screen)
        return screen
    }

    /** Every preference on [screen], flattened to maps for the method channel. */
    fun read(screen: PreferenceScreen): List<Map<String, Any?>> =
        (0 until screen.preferenceCount).map { describe(screen.getPreference(it)) }

    private fun describe(pref: Preference): Map<String, Any?> {
        val base = mutableMapOf<String, Any?>(
            "key" to (pref.key ?: ""),
            "title" to (pref.title?.toString() ?: ""),
            "summary" to (pref.summary?.toString() ?: ""),
        )
        when (pref) {
            // SwitchPreferenceCompat extends TwoStatePreference, as does
            // CheckBoxPreference — check the concrete types, not the parent, so
            // each keeps the control the source asked for.
            is SwitchPreferenceCompat -> {
                base["type"] = TYPE_SWITCH
                base["value"] = pref.isChecked
            }
            is CheckBoxPreference -> {
                base["type"] = TYPE_CHECKBOX
                base["value"] = pref.isChecked
            }
            is MultiSelectListPreference -> {
                base["type"] = TYPE_MULTI
                base["entries"] = pref.entries.map { it.toString() }
                base["values"] = pref.entryValues.map { it.toString() }
                base["value"] = pref.values.toList()
            }
            // After MultiSelect: it is NOT a ListPreference, but keeping the
            // order explicit stops a future reorder from silently reclassifying
            // it as a single-choice list.
            is ListPreference -> {
                base["type"] = TYPE_LIST
                base["entries"] = pref.entries.map { it.toString() }
                base["values"] = pref.entryValues.map { it.toString() }
                base["value"] = pref.value
            }
            is EditTextPreference -> {
                base["type"] = TYPE_TEXT
                base["value"] = pref.text
            }
            else -> base["type"] = TYPE_UNKNOWN
        }
        return base
    }

    /**
     * Apply [value] to [key] on [screen]. Returns false when the key is gone,
     * the type does not match, or the source's own listener refuses it.
     *
     * The listener runs FIRST and its verdict decides. Sources do real work in
     * there — a domain switcher rebuilds its base url, a language toggle clears
     * a cache — so writing to SharedPreferences directly would save the value
     * and leave the source none the wiser. This is the same call the native
     * screen makes when you tap the row.
     */
    fun write(screen: PreferenceScreen, key: String, value: Any?): Boolean {
        val pref = screen.findPreference<Preference>(key) ?: return false
        return when (pref) {
            is SwitchPreferenceCompat -> {
                val v = value as? Boolean ?: return false
                if (!pref.callChangeListener(v)) return false
                pref.isChecked = v
                true
            }
            is CheckBoxPreference -> {
                val v = value as? Boolean ?: return false
                if (!pref.callChangeListener(v)) return false
                pref.isChecked = v
                true
            }
            is MultiSelectListPreference -> {
                @Suppress("UNCHECKED_CAST")
                val v = (value as? List<String>)?.toSet() ?: return false
                if (!pref.callChangeListener(v)) return false
                pref.values = v
                true
            }
            is ListPreference -> {
                val v = value as? String ?: return false
                if (!pref.callChangeListener(v)) return false
                pref.value = v
                true
            }
            is EditTextPreference -> {
                val v = value as? String ?: return false
                if (!pref.callChangeListener(v)) return false
                pref.text = v
                true
            }
            else -> false
        }
    }
}
