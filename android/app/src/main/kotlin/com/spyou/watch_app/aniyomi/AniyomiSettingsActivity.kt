package com.spyou.watch_app.aniyomi

import android.os.Bundle
import android.util.TypedValue
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.Toolbar
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
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

        // Header (Toolbar) ABOVE a fragment container, so the extension's
        // preference list always sits BELOW the header. Previously the fragment
        // filled android.R.id.content and the action bar overlaid its first row.
        val toolbar = Toolbar(this).apply {
            setBackgroundColor(themeColor(androidx.appcompat.R.attr.colorPrimary))
        }
        val container = FrameLayout(this).apply {
            id = CONTAINER_ID
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(
                toolbar,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
            addView(container)
        }
        setContentView(root)

        setSupportActionBar(toolbar)
        title = source.name
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        // Android 15+/targetSdk 36 draws edge-to-edge by default: inset the whole
        // screen by the system bars so the header sits below the status bar and
        // the list stays above the nav bar.
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }

        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction()
                .replace(CONTAINER_ID, AniyomiPrefFragment.newInstance(sourceId))
                .commit()
        }
    }

    private fun themeColor(attr: Int): Int {
        val tv = TypedValue()
        theme.resolveAttribute(attr, tv, true)
        return tv.data
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }

    companion object {
        const val EXTRA_SOURCE_ID = "sourceId"
        private const val CONTAINER_ID = 0x00AA0001
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
