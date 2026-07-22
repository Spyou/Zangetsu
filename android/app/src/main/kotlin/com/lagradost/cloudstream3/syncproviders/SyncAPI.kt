package com.lagradost.cloudstream3.syncproviders

import com.lagradost.cloudstream3.ActorData
import com.lagradost.cloudstream3.NextAiring
import com.lagradost.cloudstream3.Score
import com.lagradost.cloudstream3.SearchQuality
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.ShowStatus
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.ui.SyncWatchType
import com.lagradost.cloudstream3.ui.library.ListSorting
import com.lagradost.cloudstream3.utils.UiText
import java.util.Date

/**
 * Clean-room LINK STUB of CloudStream's account/sync API.
 *
 * The bundled `com.github.recloudstream.cloudstream:library:v4.7.0` AAR ships the
 * top-level model classes (Score, ActorData, TvType, NextAiring, ShowStatus,
 * SearchQuality, SearchResponse, SyncIdName) but NOT AuthAPI / SyncAPI (those live
 * in CloudStream's `app/` module). Native .cs3 plugins still link against them, so
 * these stubs exist purely to (a) compile and (b) let plugins subclass. There is no
 * real account: every method returns null/empty/default. Signatures match
 * CloudStream master.
 *
 * SyncWatchType, UiText, ListSorting and AuthData/AuthToken/AuthUser/etc. are
 * provided by sibling stub files (referenced by name/FQN, not defined here).
 */
abstract class AuthAPI {
    open val name: String = "NONE"
    open val idPrefix: String = "NONE"
    open val icon: Int? = null
    open val requiresLogin: Boolean = true
    open val createAccountUrl: String? = null
    open val redirectUrlIdentifier: String? = null
    open val hasOAuth2: Boolean = false
    open val hasPin: Boolean = false
    open val hasInApp: Boolean = false
    open val inAppLoginRequirement: AuthLoginRequirement? = null

    open fun isValidRedirectUrl(url: String): Boolean =
        redirectUrlIdentifier != null && url.contains("/$redirectUrlIdentifier")

    open suspend fun login(redirectUrl: String, payload: String?): AuthToken? = null
    open fun loginRequest(): AuthLoginPage? = null
    open suspend fun pinRequest(): AuthPinData? = null
    open suspend fun refreshToken(token: AuthToken): AuthToken? = null
    open suspend fun login(payload: AuthPinData): AuthToken? = null
    open suspend fun login(form: AuthLoginResponse): AuthToken? = null
    open suspend fun user(token: AuthToken?): AuthUser? = null
    open suspend fun invalidateToken(token: AuthToken): Nothing = throw NotImplementedError()
}

abstract class SyncAPI : AuthAPI() {
    open var requireLibraryRefresh: Boolean = true
    open val mainUrl: String = "NONE"
    open val supportedWatchTypes: Set<SyncWatchType> = emptySet()
    open val syncIdName: SyncIdName? = null

    open suspend fun updateStatus(
        auth: AuthData?,
        id: String,
        newStatus: AbstractSyncStatus
    ): Boolean = false

    open suspend fun status(auth: AuthData?, id: String): AbstractSyncStatus? = null

    open suspend fun load(auth: AuthData?, id: String): SyncResult? = null

    open suspend fun search(auth: AuthData?, query: String): List<SyncSearchResult>? = null

    open suspend fun library(auth: AuthData?): LibraryMetadata? = null

    open fun urlToId(url: String): String? = null

    data class SyncSearchResult(
        override val name: String,
        override val apiName: String,
        var syncId: String,
        override val url: String,
        override var posterUrl: String?,
        override var type: TvType? = null,
        override var quality: SearchQuality? = null,
        override var posterHeaders: Map<String, String>? = null,
        override var id: Int? = null,
        override var score: Score? = null,
    ) : SearchResponse

    abstract class AbstractSyncStatus {
        abstract var status: SyncWatchType
        abstract var score: Score?
        abstract var watchedEpisodes: Int?
        abstract var isFavorite: Boolean?
        abstract var maxEpisodes: Int?
    }

    data class SyncStatus(
        override var status: SyncWatchType,
        override var score: Score?,
        override var watchedEpisodes: Int?,
        override var isFavorite: Boolean? = null,
        override var maxEpisodes: Int? = null,
    ) : AbstractSyncStatus()

    data class SyncResult(
        /**Used to verify*/
        var id: String = "",
        var totalEpisodes: Int? = null,
        var title: String? = null,
        var publicScore: Score? = null,
        /**In minutes*/
        var duration: Int? = null,
        var synopsis: String? = null,
        var airStatus: ShowStatus? = null,
        var nextAiring: NextAiring? = null,
        var studio: List<String>? = null,
        var genres: List<String>? = null,
        var synonyms: List<String>? = null,
        var trailers: List<String>? = null,
        var isAdult: Boolean? = null,
        var posterUrl: String? = null,
        var backgroundPosterUrl: String? = null,
        /** In unixtime */
        var startDate: Long? = null,
        /** In unixtime */
        var endDate: Long? = null,
        var recommendations: List<SyncSearchResult>? = null,
        var nextSeason: SyncSearchResult? = null,
        var prevSeason: SyncSearchResult? = null,
        var actors: List<ActorData>? = null,
    )

    // ponytail: real Page has a sort() over Levenshtein/ListSorting; dropped the body
    // since no plugin links against sorting. Add it back if one does.
    data class Page(
        val title: UiText,
        var items: List<LibraryItem>
    )

    data class LibraryMetadata(
        val allLibraryLists: List<LibraryList>,
        val supportedListSorting: Set<ListSorting> = emptySet()
    )

    data class LibraryList(
        val name: UiText,
        val items: List<LibraryItem>
    )

    data class LibraryItem(
        override val name: String,
        override val url: String,
        val syncId: String,
        val episodesCompleted: Int?,
        val episodesTotal: Int?,
        val personalRating: Score?,
        val lastUpdatedUnixTime: Long?,
        override val apiName: String,
        override var type: TvType?,
        override var posterUrl: String?,
        override var posterHeaders: Map<String, String>?,
        override var quality: SearchQuality?,
        val releaseDate: Date?,
        override var id: Int? = null,
        val plot: String? = null,
        override var score: Score? = null,
        val tags: List<String>? = null
    ) : SearchResponse
}
