package com.lagradost.cloudstream3.syncproviders

/**
 * Clean-room link stubs for CloudStream's auth + sync-repo layer, which lives in
 * CloudStream's app module and is NOT in the bundled `:library`. Compile/link only
 * — every method returns null/empty at runtime (no real account). Referenced by
 * [SyncAPI] / [AccountManager] / AniListApi. Additive: only previously-failing
 * plugins (StreamPlay/StreamCenter/TorraStream) reference these.
 */

data class AuthToken(
    val accessToken: String? = null,
    val refreshToken: String? = null,
    val accessTokenLifetime: Long? = null,
    val refreshTokenLifetime: Long? = null,
    val payload: String? = null,
)

data class AuthUser(
    val name: String? = null,
    val id: Int? = null,
    val profilePicture: String? = null,
    val profilePictureHeaders: Map<String, String>? = null,
)

data class AuthData(
    val user: AuthUser? = null,
    val token: AuthToken? = null,
)

// Support types referenced ONLY by AuthAPI's method signatures (see SyncAPI.kt).
// Plugins never construct or read these — empty stubs are enough to link.
class AuthLoginPage(val url: String = "", val payload: String? = null)
class AuthPinData
class AuthLoginRequirement
class AuthLoginResponse

abstract class AuthRepo(open val api: AuthAPI) {
    open val name: String get() = api.name
    // Real CloudStream declares this as a METHOD — the plugin bytecode calls
    // authData() (no `get` prefix), so it must NOT be a property getter.
    fun authData(): AuthData? = null
}

class SyncRepo(override val api: SyncAPI) : AuthRepo(api) {
    val syncIdName get() = api.syncIdName
    fun authUser(): AuthUser? = null
    suspend fun library(): kotlin.Result<SyncAPI.LibraryMetadata?> = kotlin.Result.success(null)
}
