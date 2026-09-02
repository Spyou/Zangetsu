package com.spyou.watch_app.mihon

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The two modes must be two tasks.
 *
 * Both launch sites use `FLAG_ACTIVITY_NEW_TASK`, and Android picks the task to
 * reuse with `Intent.filterEquals` — which ignores extras. When a login intent
 * and a Cloudflare intent compare equal, a login screen left in the background
 * is reused for a solve, `onCreate` never runs, and the Dart call waiting on
 * that solve is never answered. That is what these assertions guard.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SourceWebViewIntentTest {

    private val ctx: Context get() = ApplicationProvider.getApplicationContext()

    @Test
    fun `a login intent never matches a cloudflare intent`() {
        val login = SourceWebViewActivity.intentFor(ctx, URL_A, stayOpen = true, title = "A")
        val solve = SourceWebViewActivity.intentFor(ctx, URL_A, stayOpen = false)
        assertFalse(login.filterEquals(solve))
        assertFalse(solve.filterEquals(login))
    }

    @Test
    fun `two cloudflare intents still share one task`() {
        // Today's behaviour, kept: a solve holds a single pending Dart result,
        // so two solver tasks at once would let the older one answer the newer
        // one's call.
        assertTrue(
            SourceWebViewActivity.intentFor(ctx, URL_A, stayOpen = false)
                .filterEquals(SourceWebViewActivity.intentFor(ctx, URL_B, stayOpen = false)),
        )
    }

    @Test
    fun `two sources get two login screens`() {
        assertFalse(
            SourceWebViewActivity.intentFor(ctx, URL_A, stayOpen = true)
                .filterEquals(SourceWebViewActivity.intentFor(ctx, URL_B, stayOpen = true)),
        )
    }

    @Test
    fun `the mode still reaches the activity as an extra`() {
        val login = SourceWebViewActivity.intentFor(ctx, URL_A, stayOpen = true, title = "A")
        assertTrue(login.getBooleanExtra(SourceWebViewActivity.EXTRA_STAY_OPEN, false))
        assertFalse(
            SourceWebViewActivity.intentFor(ctx, URL_A, stayOpen = false)
                .getBooleanExtra(SourceWebViewActivity.EXTRA_STAY_OPEN, false),
        )
    }

    private companion object {
        const val URL_A = "https://www.novelupdates.com/"
        const val URL_B = "https://asuracomic.net/"
    }
}
