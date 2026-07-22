package com.lagradost.cloudstream3.syncproviders

/**
 * Clean-room STUB of CloudStream's AccountManager.
 *
 * The bundled `com.github.recloudstream.cloudstream:library:v4.7.0` does NOT ship
 * the syncproviders / AniList API, but some native .cs3 plugins link against them
 * (e.g. `AccountManager.getAniListApi()`, `getAllApis()`, `getSyncApis()`).
 *
 * This exists only so those plugins LINK and COMPILE. Everything returns
 * null/empty/defaults — there is no real account, login, or list sync.
 *
 * ponytail: minimal on purpose. We construct ONLY AniListApi (no MAL/Trakt/Kitsu/
 * subtitle providers, no SyncRepo/SubtitleRepo wrappers). Add those only if a plugin
 * is found that actually links against them.
 */
abstract class AccountManager {
    companion object {
        const val NONE_ID: Int = -1

        @JvmStatic
        val aniListApi = com.lagradost.cloudstream3.syncproviders.providers.AniListApi()

        // Real CS wraps these in SyncRepo(...); plugins that only read the array/idPrefix
        // work fine with the bare api. Keep it flat and minimal.
        @JvmStatic
        val allApis = arrayOf(aniListApi)

        @JvmStatic
        val syncApis = arrayOf(aniListApi)

        // App deep-link strings some plugins reference off AccountManager.
        const val APP_STRING = "cloudstreamapp"
        const val APP_STRING_REPO = "cloudstreamrepo"
        const val APP_STRING_PLAYER = "cloudstreamplayer"
        const val APP_STRING_SEARCH = "cloudstreamsearch"
        const val APP_STRING_RESUME_WATCHING = "cloudstreamcontinuewatching"
        const val APP_STRING_SHARE = "csshare"

        const val ACCOUNT_TOKEN = "auth_tokens"
        const val ACCOUNT_IDS = "auth_ids"
    }
}
