package com.spyou.watch_app.aniyomi

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import eu.kanade.tachiyomi.network.NetworkHelper
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

/**
 * Verifies that [AniyomiInjektModules.ensureRegistered] stands up the injekt
 * graph so that [NetworkHelper] (and other bindings) resolve without error.
 *
 * Runs under Robolectric so [ApplicationProvider.getApplicationContext] returns
 * a real (shadowed) [android.app.Application] without needing a device. Pinned
 * to SDK 34 — the highest API level Robolectric 4.12.2 supports.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AniyomiInjektModulesTest {

    @Test
    fun graph_resolves_networkhelper() {
        val ctx = ApplicationProvider.getApplicationContext<Context>()
        AniyomiInjektModules.ensureRegistered(ctx)
        assertNotNull(Injekt.get<NetworkHelper>())
    }
}
