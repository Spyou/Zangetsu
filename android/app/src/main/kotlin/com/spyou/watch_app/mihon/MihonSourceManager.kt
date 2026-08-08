/*
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
 * Adapted from the Mihon project (https://github.com/mihonapp/mihon)
 * for host-side source management in the Zangetsu app.
 */
package com.spyou.watch_app.mihon

import eu.kanade.tachiyomi.source.Source

/**
 * Thread-safe registry of all loaded Mihon manga [Source] instances.
 *
 * Sources are indexed by their [Source.id] for O(1) lookup. The originating
 * [MihonLoadedExtension] list is kept alongside so callers can enumerate
 * installed extensions (e.g. to display them in the UI or to re-register
 * them after a restart).
 *
 * Re-registering an extension with the same package name replaces the
 * previous entry — sources from the old extension are evicted and the
 * new extension's sources replace them.
 *
 * This is a deliberate near-duplicate of `AniyomiSourceManager` — see that
 * file for the anime-source equivalent. Kept separate (not parameterised
 * into one shared manager) so the anime path is never touched by manga
 * changes.
 */
object MihonSourceManager {

    private val sources = LinkedHashMap<Long, Source>()
    private val extensions = ArrayList<MihonLoadedExtension>()

    /**
     * Registers [ext] and indexes its sources by [Source.id].
     *
     * If an extension with the same [MihonLoadedExtension.pkg] is already registered,
     * its sources are removed from the index before the new sources are added.
     */
    @Synchronized
    fun register(ext: MihonLoadedExtension) {
        // Remove any existing sources from this package before re-indexing.
        val previous = extensions.find { it.pkg == ext.pkg }
        if (previous != null) {
            previous.sources.forEach { sources.remove(it.id) }
            extensions.remove(previous)
        }
        extensions.add(ext)
        ext.sources.forEach { sources[it.id] = it }
    }

    /**
     * Returns the [Source] with the given [id], or null if not registered.
     */
    @Synchronized
    fun get(id: Long): Source? = sources[id]

    /**
     * Returns a snapshot of all currently installed [MihonLoadedExtension]s.
     */
    @Synchronized
    fun installed(): List<MihonLoadedExtension> = extensions.toList()

    /**
     * Returns a snapshot of all registered [Source] instances in insertion order.
     */
    @Synchronized
    fun all(): List<Source> = sources.values.toList()
}
