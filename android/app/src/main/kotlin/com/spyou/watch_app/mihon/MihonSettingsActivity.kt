package com.spyou.watch_app.mihon

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
import eu.kanade.tachiyomi.source.ConfigurableSource

/**
 * A full-screen [AppCompatActivity] that hosts a Mihon extension's own
 * preferences UI. Sources that implement [ConfigurableSource] populate a
 * [PreferenceFragmentCompat] via [ConfigurableSource.setupPreferenceScreen].
 *
 * Preferences are stored in a [android.content.SharedPreferences] named
 * `"source_<id>"` — the same key the extension reads at runtime via
 * [eu.kanade.tachiyomi.source.preferenceKey].
 *
 * Launch via an [android.content.Intent] with [EXTRA_SOURCE_ID] set to the
 * source's numeric id (Long). The activity finishes immediately when the source
 * is not found or does not implement [ConfigurableSource].
 *
 * Structural twin of `AniyomiSettingsActivity` — kept as a separate copy so the
 * anime path never has to change for a manga change.
 */
class MihonSettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val sourceId = intent.getLongExtra(EXTRA_SOURCE_ID, -1L)
        if (sourceId == -1L) { finish(); return }

        val source = MihonSourceManager.get(sourceId)
        if (source !is ConfigurableSource) { finish(); return }

        // Header (Toolbar) ABOVE a fragment container, so the extension's
        // preference list always sits BELOW the header rather than being
        // overlaid by the action bar.
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
                .replace(CONTAINER_ID, MihonPrefFragment.newInstance(sourceId))
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

        // Distinct from AniyomiSettingsActivity's container id — these are two
        // separate activities, but keeping the ids apart avoids any confusion if
        // one is ever hosted inside the other's hierarchy.
        private const val CONTAINER_ID = 0x00AA0002
    }

    /**
     * A [PreferenceFragmentCompat] that delegates preference construction to the
     * source. The shared-preferences name is scoped to `"source_<sourceId>"` so
     * writes land in the same store the source reads at runtime.
     */
    class MihonPrefFragment : PreferenceFragmentCompat() {

        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            val sourceId = requireArguments().getLong(EXTRA_SOURCE_ID)
            val source = MihonSourceManager.get(sourceId) as? ConfigurableSource
                ?: return
            preferenceManager.sharedPreferencesName = "source_$sourceId"
            val screen = preferenceManager.createPreferenceScreen(requireContext())
            source.setupPreferenceScreen(screen)
            preferenceScreen = screen
        }

        companion object {
            fun newInstance(sourceId: Long): MihonPrefFragment =
                MihonPrefFragment().apply {
                    arguments = Bundle().apply { putLong(EXTRA_SOURCE_ID, sourceId) }
                }
        }
    }
}
