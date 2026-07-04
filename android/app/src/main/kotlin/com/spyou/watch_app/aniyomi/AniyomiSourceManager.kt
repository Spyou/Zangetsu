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
 * Adapted from the Aniyomi project (https://github.com/aniyomiorg/aniyomi)
 * for host-side source management in the Zangetsu app.
 */
package com.spyou.watch_app.aniyomi

import eu.kanade.tachiyomi.animesource.AnimeSource

/**
 * Thread-safe registry of all loaded Aniyomi [AnimeSource] instances.
 *
 * Sources are indexed by their [AnimeSource.id] for O(1) lookup. The
 * originating [LoadedExtension] list is kept alongside so callers can
 * enumerate installed extensions (e.g. to display them in the UI or to
 * re-register them after a restart).
 *
 * Re-registering an extension with the same package name replaces the
 * previous entry — sources from the old extension are evicted and the
 * new extension's sources replace them.
 */
object AniyomiSourceManager {

    private val sources = LinkedHashMap<Long, AnimeSource>()
    private val extensions = ArrayList<LoadedExtension>()

    /**
     * Registers [ext] and indexes its sources by [AnimeSource.id].
     *
     * If an extension with the same [LoadedExtension.pkg] is already registered,
     * its sources are removed from the index before the new sources are added.
     */
    @Synchronized
    fun register(ext: LoadedExtension) {
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
     * Returns the [AnimeSource] with the given [id], or null if not registered.
     */
    @Synchronized
    fun get(id: Long): AnimeSource? = sources[id]

    /**
     * Returns a snapshot of all currently installed [LoadedExtension]s.
     */
    @Synchronized
    fun installed(): List<LoadedExtension> = extensions.toList()

    /**
     * Returns a snapshot of all registered [AnimeSource] instances in insertion order.
     */
    @Synchronized
    fun all(): List<AnimeSource> = sources.values.toList()
}
