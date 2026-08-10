package com.lagradost.cloudstream3.syncproviders.providers

import com.lagradost.cloudstream3.syncproviders.AuthData
import com.lagradost.cloudstream3.syncproviders.AuthToken
import com.lagradost.cloudstream3.syncproviders.AuthUser
import com.lagradost.cloudstream3.syncproviders.AuthLoginPage
import com.lagradost.cloudstream3.syncproviders.SyncAPI
import com.lagradost.cloudstream3.syncproviders.SyncIdName

/**
 * Clean-room STUB of CloudStream's Simkl sync API — a 1:1 mirror of [AniListApi].
 *
 * The bundled `com.github.recloudstream.cloudstream:library:v4.7.0` predates Simkl
 * sync, so it doesn't ship this class or `AccountManager.getSimklApi()`. Newer
 * .cs3 plugins link against them (e.g. CineStream registers a CineSimkl catalog in
 * its `load()`), so without these the plugin's `load()` throws a NoSuchMethodError
 * partway through and never finishes — which is why such a source works but shows
 * no settings. This exists only so those plugins LINK and LOAD; there is NO real
 * Simkl login or sync — every method returns null/false/empty.
 *
 * See [AniListApi] for the inheritance note (extends [SyncAPI] directly).
 */
class SimklApi : SyncAPI() {
    override val name = "Simkl"
    override val idPrefix = "simkl"
    override val icon: Int? = null
    override val requiresLogin = true
    override val mainUrl = "https://simkl.com"
    override val redirectUrlIdentifier = "simkllogin"
    override val createAccountUrl = "https://simkl.com/signup"
    override val hasOAuth2 = true
    // null (not SyncIdName.Simkl) — avoids depending on a specific enum entry in the
    // bundled library; plugins read it as null and handle it.
    override val syncIdName: SyncIdName? = null

    // --- AuthAPI (OAuth) — no real login ---
    override fun loginRequest(): AuthLoginPage? = null
    override suspend fun login(redirectUrl: String, payload: String?): AuthToken? = null
    override suspend fun refreshToken(token: AuthToken): AuthToken? = null
    override suspend fun user(token: AuthToken?): AuthUser? = null

    // --- SyncAPI — no real sync ---
    override fun urlToId(url: String): String? = null
    override suspend fun search(auth: AuthData?, query: String): List<SyncSearchResult>? = null
    override suspend fun load(auth: AuthData?, id: String): SyncResult? = null
    override suspend fun status(auth: AuthData?, id: String): AbstractSyncStatus? = null
    override suspend fun library(auth: AuthData?): LibraryMetadata? = null
    override suspend fun updateStatus(
        auth: AuthData?,
        id: String,
        newStatus: AbstractSyncStatus
    ): Boolean = false
}
