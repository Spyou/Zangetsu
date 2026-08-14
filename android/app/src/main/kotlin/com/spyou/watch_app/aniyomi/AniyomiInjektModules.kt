/*
 * Copyright 2015 Javier Tomás
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Adapted from the Aniyomi project (https://github.com/aniyomiorg/aniyomi)
 * for host-side injection into the Aniyomi extension runtime.
 */
package com.spyou.watch_app.aniyomi

import android.app.Application
import android.content.Context
import android.util.Log
import eu.kanade.tachiyomi.network.NetworkHelper
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.InjektModule
import uy.kohesive.injekt.api.InjektRegistrar
import uy.kohesive.injekt.api.addSingleton
import uy.kohesive.injekt.api.get

/**
 * Stands up the injekt graph that Aniyomi anime extensions resolve through
 * `injectLazy()` calls on first use.
 *
 * The graph is initialised **lazily** — [ensureRegistered] must be called before
 * any extension is loaded, but it must NOT be called at app boot (the feature is
 * additive and must not affect startup time). The idempotent guard makes repeated
 * calls after the first registration safe from any thread.
 *
 * Registered bindings:
 *   - [Application]          — app context, used by extensions for resources/prefs
 *   - [NetworkHelper]        — wraps the app's shared OkHttp (CF solver, cookie jar,
 *                              optional DoH); extensions reach it via `injectLazy()`
 *   - [Json]                 — kotlinx-serialization instance (ignoreUnknownKeys)
 *   - [SourcePreferences]    — thin SharedPreferences wrapper; store name
 *                              `"zangetsu_aniyomi"` so all Aniyomi state is in one
 *                              named file
 */
object AniyomiInjektModules {

    private const val TAG = "AniyomiInjekt"

    @Volatile private var registered = false

    /**
     * Idempotent. Registers the Aniyomi injekt graph on first call; subsequent
     * calls return immediately. Thread-safe via double-checked locking.
     *
     * The [NetworkHelper] wired here uses the app's shared [OkHttpClient]
     * (`com.lagradost.cloudstream3.app.baseClient`), which already carries the
     * WebView Cloudflare solver, the WebKit cookie jar, and the optional
     * DNS-over-HTTPS interceptor. All Aniyomi extensions therefore share one HTTP
     * stack with the rest of the app.
     *
     * One-time log marker emitted on first registration — used externally to verify
     * that the graph is NOT initialised during cold start.
     */
    fun ensureRegistered(context: Context) {
        if (registered) return
        synchronized(this) {
            if (registered) return
            Log.i(TAG, "aniyomi-injekt-init: registering graph")

            val app = context.applicationContext as Application

            // Reuse the app's shared OkHttp client so Aniyomi extensions share
            // the Cloudflare solver, cookie jar, and DNS-over-HTTPS stack.
            // Fall back to a plain OkHttpClient when the CS runtime has not yet
            // set baseClient (test environments, or unusual boot ordering).
            val shared: OkHttpClient = runCatching {
                com.lagradost.cloudstream3.app.baseClient
            }.getOrElse { OkHttpClient() }

            // …but NOT CloudStream's UA-realigning network interceptor.
            //
            // It rewrites the User-Agent of any request carrying a cf_clearance
            // cookie to the UA *CloudStream's* WebView solver used, which is
            // persisted to disk and can be from a much older solve. That's right
            // for CloudStream (NiceHttp otherwise sends a desktop UA the cookie
            // wasn't issued to) and wrong for extensions, which solve their own
            // challenges: the clearance gets bound to the UA the extension's
            // solve ran under, then this swaps a different UA onto the wire.
            // Cloudflare sees a cookie issued to one browser presented by
            // another and challenges forever — the user solves, passes, and is
            // blocked again on the very next request.
            //
            // It runs at the NETWORK layer, below the extension client's own
            // interceptors, so nothing above can see or undo it. Dropping it
            // here leaves extension traffic with exactly one Cloudflare
            // identity, the way upstream Aniyomi/Mihon has it. CloudStream's own
            // client keeps the interceptor untouched.
            val extensionClient: OkHttpClient = shared.newBuilder()
                .apply {
                    networkInterceptors().removeAll {
                        it === com.spyou.watch_app.cloudstream.CfClearance.interceptor
                    }
                }
                .build()

            Injekt.importModule(object : InjektModule {
                // InjektModule.registerInjectables is defined as an extension
                // function on InjektRegistrar; 'this' inside the body is the
                // InjektRegistrar, so addSingleton is called as an extension.
                override fun InjektRegistrar.registerInjectables() {
                    addSingleton(app)
                    addSingleton(NetworkHelper(app, extensionClient))
                    addSingleton(Json { ignoreUnknownKeys = true })
                    addSingleton(
                        SourcePreferences(
                            app.getSharedPreferences("zangetsu_aniyomi", Context.MODE_PRIVATE),
                        ),
                    )
                }
            })

            registered = true
        }
    }
}
