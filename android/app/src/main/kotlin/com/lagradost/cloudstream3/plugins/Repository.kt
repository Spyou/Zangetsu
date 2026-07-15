package com.lagradost.cloudstream3.plugins

/**
 * App-internal CloudStream repository manifest, NOT in the bundled `library`
 * artifact. Vendored so "mega repo" plugins (which call
 * [RepositoryManager.parseRepository]) resolve. Only the members those plugins
 * read are provided (name / iconUrl / pluginLists).
 */
data class Repository(
    val name: String,
    val description: String? = null,
    val manifestVersion: Int = 1,
    val pluginLists: List<String> = emptyList(),
    val iconUrl: String? = null,
)
