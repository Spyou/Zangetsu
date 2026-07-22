package com.lagradost.cloudstream3.syncproviders.providers

import com.lagradost.cloudstream3.syncproviders.AuthData
import com.lagradost.cloudstream3.syncproviders.AuthToken
import com.lagradost.cloudstream3.syncproviders.AuthUser
import com.lagradost.cloudstream3.syncproviders.AuthLoginPage
import com.lagradost.cloudstream3.syncproviders.SyncAPI
import com.lagradost.cloudstream3.syncproviders.SyncIdName

/**
 * Clean-room STUB of CloudStream's AniList sync API.
 *
 * Only exists so native .cs3 plugins that link against `AniListApi` (and its nested
 * data classes) compile and load. There is NO real AniList login or sync here — every
 * method returns null/false/empty.
 *
 * NOTE ON INHERITANCE: the real `SyncAPI` is `abstract class SyncAPI : AuthAPI()`, so
 * AniListApi extends it directly (Kotlin can't extend AccountManager AND SyncAPI, and
 * plugins reach AccountManager through its static companion, not through this instance).
 *
 * ponytail: SyncAPI/AuthAPI members are all `open` with defaults, so nothing is forced.
 * We override only what plugins call, flipping the throwing defaults to null/false so a
 * linked plugin gets a graceful empty instead of a crash.
 */
class AniListApi : SyncAPI() {
    override val name = "AniList"
    override val idPrefix = "anilist"
    override val icon: Int? = null
    override val requiresLogin = true
    override val mainUrl = "https://anilist.co"
    override val redirectUrlIdentifier = "anilistlogin"
    override val createAccountUrl = "https://anilist.co/signup"
    override val hasOAuth2 = true
    // null (not SyncIdName.Anilist) — avoids depending on a specific enum entry in
    // the bundled library; plugins read it as null and handle it.
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

    // --- Nested data classes plugins reference (e.g. AniListApi.CoverImage) ---
    // All fields default to null/empty so they construct with no args.

    data class CoverImage(
        val medium: String? = null,
        val large: String? = null,
        val extraLarge: String? = null,
    )

    data class Title(
        val english: String? = null,
        val romaji: String? = null,
    )

    data class MediaTitle(
        val romaji: String? = null,
        val english: String? = null,
        val native: String? = null,
        val userPreferred: String? = null,
    )

    data class MediaCoverImage(
        val extraLarge: String? = null,
        val large: String? = null,
        val medium: String? = null,
        val color: String? = null,
    )

    // Real source: `title` is `Title?` (not MediaTitle?); also carries idMal/averageScore.
    data class RecommendedMedia(
        val id: Int? = null,
        val title: Title? = null,
        val idMal: Int? = null,
        val coverImage: CoverImage? = null,
        val averageScore: Int? = null,
    )

    data class Recommendation(
        val mediaRecommendation: RecommendedMedia? = null,
    )

    // Real source: `node` is non-null; defaulted here so it constructs with no args.
    data class RecommendationEdge(
        val node: Recommendation? = null,
    )

    data class RecommendationConnection(
        val edges: List<RecommendationEdge> = emptyList(),
        val nodes: List<Recommendation> = emptyList(),
    )

    data class SeasonNextAiringEpisode(
        val episode: Int? = null,
        val timeUntilAiring: Int? = null,
    )

    data class LikePageInfo(
        val total: Int? = null,
        val currentPage: Int? = null,
        val lastPage: Int? = null,
        val perPage: Int? = null,
        val hasNextPage: Boolean? = null,
    )
}
