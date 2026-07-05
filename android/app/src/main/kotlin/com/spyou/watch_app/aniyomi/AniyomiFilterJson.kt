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
 * for host-side filter serialisation in the Zangetsu app.
 */
package com.spyou.watch_app.aniyomi

import eu.kanade.tachiyomi.animesource.model.AnimeFilter
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import org.json.JSONArray
import org.json.JSONObject

/**
 * Pure serialisation helpers that convert [AnimeFilterList] objects to/from
 * the JSON shapes exchanged with the Dart [AniyomiFilters] layer.
 *
 * ## Schema JSON ([filterListToJson])
 * An ordered JSON array where each element is an object with at minimum
 * `"type"` and `"name"` fields. Element order matches [AnimeFilterList.list]
 * exactly — positions are the join key used when applying selections.
 *
 * ## Selection JSON ([applySelectionJson])
 * The Dart layer re-emits the full schema array with mutated `state` fields.
 * [applySelectionJson] iterates positions and mutates the live filter list in
 * place. All parsing errors are swallowed; a bad/missing element is skipped.
 *
 * This object has no Android / Context dependencies and is unit-testable on
 * the plain JVM.
 */
object AniyomiFilterJson {

    // -------------------------------------------------------------------------
    // Serialisation — AnimeFilterList → JSON string
    // -------------------------------------------------------------------------

    /**
     * Serialises [list] to an ordered JSON array string.
     *
     * Each element is a JSON object whose shape is determined by the filter's
     * concrete subtype (see [filterToJson]).
     */
    fun filterListToJson(list: AnimeFilterList): String {
        val arr = JSONArray()
        list.forEach { filter -> arr.put(filterToJson(filter)) }
        return arr.toString()
    }

    /**
     * Serialises a single [AnimeFilter] to a [JSONObject] per the contract:
     *
     * | type      | extra fields                                         |
     * |-----------|------------------------------------------------------|
     * | header    | (none)                                               |
     * | separator | (none)                                               |
     * | select    | values:[String,...], state:Int                       |
     * | text      | state:String                                         |
     * | checkbox  | state:Bool                                           |
     * | tristate  | state:Int                                            |
     * | sort      | values:[String,...], state:{index,ascending} or null |
     * | group     | filters:[...recursive...]                            |
     */
    private fun filterToJson(filter: AnimeFilter<*>): JSONObject = JSONObject().apply {
        put("name", filter.name)
        when (filter) {
            is AnimeFilter.Header -> {
                put("type", "header")
            }
            is AnimeFilter.Separator -> {
                put("type", "separator")
            }
            is AnimeFilter.Select<*> -> {
                put("type", "select")
                val valuesArr = JSONArray()
                filter.values.forEach { v -> valuesArr.put(v.toString()) }
                put("values", valuesArr)
                put("state", filter.state)
            }
            is AnimeFilter.Text -> {
                put("type", "text")
                put("state", filter.state)
            }
            is AnimeFilter.CheckBox -> {
                put("type", "checkbox")
                put("state", filter.state)
            }
            is AnimeFilter.TriState -> {
                put("type", "tristate")
                put("state", filter.state)
            }
            is AnimeFilter.Sort -> {
                put("type", "sort")
                val valuesArr = JSONArray()
                filter.values.forEach { v -> valuesArr.put(v) }
                put("values", valuesArr)
                val sel = filter.state
                if (sel != null) {
                    put("state", JSONObject().apply {
                        put("index", sel.index)
                        put("ascending", sel.ascending)
                    })
                } else {
                    put("state", JSONObject.NULL)
                }
            }
            is AnimeFilter.Group<*> -> {
                put("type", "group")
                @Suppress("UNCHECKED_CAST")
                val subFilters = filter.state as List<AnimeFilter<*>>
                val filtersArr = JSONArray()
                subFilters.forEach { sub -> filtersArr.put(filterToJson(sub)) }
                put("filters", filtersArr)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Application — selection JSON → mutate AnimeFilterList in place
    // -------------------------------------------------------------------------

    /**
     * Parses [selectionJson] as a JSON array and mutates the live [list]
     * in place, position by position.
     *
     * Rules per contract:
     * - Iterates `0 until min(list.size, arr.length())`.
     * - Each position: updates the matching [AnimeFilter]'s `state` from the
     *   JSON element's `"state"` field. [AnimeFilter.Header] and
     *   [AnimeFilter.Separator] are silently skipped.
     * - [AnimeFilter.Group] recurses into its sub-filter list.
     * - Any parse error, missing key, type mismatch, or out-of-range index is
     *   silently skipped — this method never throws.
     */
    fun applySelectionJson(list: AnimeFilterList, selectionJson: String) {
        runCatching {
            val arr   = JSONArray(selectionJson)
            val count = minOf(list.size, arr.length())
            for (i in 0 until count) {
                runCatching {
                    val elem = arr.getJSONObject(i)
                    applyElement(list[i], elem)
                }
            }
        }
    }

    /**
     * Applies a single JSON element's state onto [filter], mutating it in
     * place. All type-cast and key-access errors are absorbed via [runCatching].
     */
    @Suppress("UNCHECKED_CAST")
    private fun applyElement(filter: AnimeFilter<*>, elem: JSONObject) {
        when (filter) {
            is AnimeFilter.Header, is AnimeFilter.Separator -> return

            is AnimeFilter.Select<*> -> runCatching {
                (filter as AnimeFilter<Int>).state = elem.getInt("state")
            }

            is AnimeFilter.Text -> runCatching {
                filter.state = elem.getString("state")
            }

            is AnimeFilter.CheckBox -> runCatching {
                filter.state = elem.getBoolean("state")
            }

            is AnimeFilter.TriState -> runCatching {
                (filter as AnimeFilter<Int>).state = elem.getInt("state")
            }

            is AnimeFilter.Sort -> runCatching {
                val stateRaw = elem.opt("state")
                if (stateRaw != null && stateRaw !== JSONObject.NULL) {
                    val stateObj = elem.getJSONObject("state")
                    filter.state = AnimeFilter.Sort.Selection(
                        stateObj.getInt("index"),
                        stateObj.getBoolean("ascending"),
                    )
                }
                // null state: leave/clear — do nothing (contract: "if null, leave/clear")
            }

            is AnimeFilter.Group<*> -> runCatching {
                val subFiltersJson = elem.getJSONArray("filters")
                val subFilters = filter.state as List<AnimeFilter<*>>
                val subCount = minOf(subFilters.size, subFiltersJson.length())
                for (j in 0 until subCount) {
                    runCatching {
                        val subElem = subFiltersJson.getJSONObject(j)
                        applyElement(subFilters[j], subElem)
                    }
                }
            }
        }
    }
}
