package com.spyou.watch_app.aniyomi

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.preference.PreferenceFragmentCompat
import eu.kanade.tachiyomi.animesource.ConfigurableAnimeSource

/**
 * A full-screen [AppCompatActivity] that hosts an Aniyomi extension's own
 * preferences UI. Sources that implement [ConfigurableAnimeSource] populate a
 * [PreferenceFragmentCompat] via [ConfigurableAnimeSource.setupPreferenceScreen].
 *
 * Preferences are stored in a [android.content.SharedPreferences] named
 * `"source_<id>"` — the same key the extension reads at runtime via
 * [eu.kanade.tachiyomi.animesource.preferenceKey].
 *
 * Launch via an [android.content.Intent] with [EXTRA_SOURCE_ID] set to the
 * source's numeric id (Long). The activity finishes immediately when the source
 * is not found or does not implement [ConfigurableAnimeSource].
 */
class AniyomiSettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val sourceId = intent.getLongExtra(EXTRA_SOURCE_ID, -1L)
        if (sourceId == -1L) { finish(); return }

        val source = AniyomiSourceManager.get(sourceId)
        if (source !is ConfigurableAnimeSource) { finish(); return }

        title = source.name
        // Show an ActionBar Up arrow so onSupportNavigateUp() can close the screen.
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction()
                .replace(android.R.id.content, AniyomiPrefFragment.newInstance(sourceId))
                .commit()
        }
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }

    companion object {
        const val EXTRA_SOURCE_ID = "sourceId"
    }

    /**
     * A [PreferenceFragmentCompat] that delegates preference construction to the
     * source. The shared-preferences name is scoped to `"source_<sourceId>"` so
     * writes land in the same store the source reads at runtime.
     */
    class AniyomiPrefFragment : PreferenceFragmentCompat() {

        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            val sourceId = requireArguments().getLong(EXTRA_SOURCE_ID)
            val source = AniyomiSourceManager.get(sourceId) as? ConfigurableAnimeSource
                ?: return
            preferenceManager.sharedPreferencesName = "source_$sourceId"
            val screen = preferenceManager.createPreferenceScreen(requireContext())
            source.setupPreferenceScreen(screen)
            preferenceScreen = screen
        }

        companion object {
            fun newInstance(sourceId: Long): AniyomiPrefFragment =
                AniyomiPrefFragment().apply {
                    arguments = Bundle().apply { putLong(EXTRA_SOURCE_ID, sourceId) }
                }
        }
    }
}
