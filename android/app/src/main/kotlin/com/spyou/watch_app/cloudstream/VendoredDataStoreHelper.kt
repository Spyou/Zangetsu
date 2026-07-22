package com.lagradost.cloudstream3.utils

import android.content.Context

/**
 * Minimal clean-room stub of CloudStream's app-module `DataStoreHelper` (the
 * multi-account + resume-watching store), which isn't in the bundled `:library`.
 * Plugins reference a few members — accounts and resume results — so we provide
 * just those, backed by "single default account / no resume" values. This app
 * has its own resume + account systems; these stay inert. Additive: only
 * previously-failing plugins reference this, so existing sources are unaffected.
 *
 * Data classes are trimmed to the fields plugins actually read (verified from
 * their bytecode: Account.keyIndex, ResumeWatchingResult.id/parentId).
 */
object DataStoreHelper {
    data class Account(val keyIndex: Int)
    data class ResumeWatchingResult(val id: Int?, val parentId: Int?)

    val currentAccount: String get() = "0"
    fun getAccounts(context: Context): List<Account> = listOf(Account(0))
    fun getCurrentAccount(): Account? = Account(0)
    fun deleteAllResumeStateIds() {}
}
