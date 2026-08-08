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
 * for host-side filter serialisation in the Zangetsu app.
 */
package com.spyou.watch_app.mihon

import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import org.json.JSONArray
import org.json.JSONObject

/**
 * Pure serialisation helpers that convert [FilterList] objects to/from
 * the JSON shapes exchanged with the Dart [MihonFilters] layer.
 *
 * ## Schema JSON ([filterListToJson])
 * An ordered JSON array where each element is an object with at minimum
 * `"type"` and `"name"` fields. Element order matches [FilterList.list]
 * exactly — positions are the join key used when applying selections.
 *
 * ## Selection JSON ([applySelectionJson])
 * The Dart layer re-emits the full schema array with mutated `state` fields.
 * [applySelectionJson] iterates positions and mutates the live filter list in
 * place. All parsing errors are swallowed; a bad/missing element is skipped.
 *
 * This object has no Android / Context dependencies and is unit-testable on
 * the plain JVM.
 *
 * This is a deliberate near-duplicate of `AniyomiFilterJson` — see that file
 * for the anime-filter equivalent. Kept separate (not parameterised into one
 * shared converter) so the anime path is never touched by manga changes.
 * [Filter] is a distinct sealed tree from `AnimeFilter` (different package,
 * no shared supertype), but its subclass set is identical: Header, Separator,
 * Select, Text, CheckBox, TriState, Group, Sort — so the JSON shapes below
 * are the same contract, just re-implemented against the manga tree's types.
 */
object MihonFilterJson {

    // -------------------------------------------------------------------------
    // Serialisation — FilterList → JSON string
    // -------------------------------------------------------------------------

    /**
     * Serialises [list] to an ordered JSON array string.
     *
     * Each element is a JSON object whose shape is determined by the filter's
     * concrete subtype (see [filterToJson]).
     */
    fun filterListToJson(list: FilterList): String {
        val arr = JSONArray()
        list.forEach { filter -> arr.put(filterToJson(filter)) }
        return arr.toString()
    }

    /**
     * Serialises a single [Filter] to a [JSONObject] per the contract:
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
    private fun filterToJson(filter: Filter<*>): JSONObject = JSONObject().apply {
        put("name", filter.name)
        when (filter) {
            is Filter.Header -> {
                put("type", "header")
            }
            is Filter.Separator -> {
                put("type", "separator")
            }
            is Filter.Select<*> -> {
                put("type", "select")
                val valuesArr = JSONArray()
                filter.values.forEach { v -> valuesArr.put(v.toString()) }
                put("values", valuesArr)
                put("state", filter.state)
            }
            is Filter.Text -> {
                put("type", "text")
                put("state", filter.state)
            }
            is Filter.CheckBox -> {
                put("type", "checkbox")
                put("state", filter.state)
            }
            is Filter.TriState -> {
                put("type", "tristate")
                put("state", filter.state)
            }
            is Filter.Sort -> {
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
            is Filter.Group<*> -> {
                put("type", "group")
                @Suppress("UNCHECKED_CAST")
                val subFilters = filter.state as List<Filter<*>>
                val filtersArr = JSONArray()
                subFilters.forEach { sub -> filtersArr.put(filterToJson(sub)) }
                put("filters", filtersArr)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Application — selection JSON → mutate FilterList in place
    // -------------------------------------------------------------------------

    /**
     * Parses [selectionJson] as a JSON array and mutates the live [list]
     * in place, position by position.
     *
     * Rules per contract:
     * - Iterates `0 until min(list.size, arr.length())`.
     * - Each position: updates the matching [Filter]'s `state` from the
     *   JSON element's `"state"` field. [Filter.Header] and
     *   [Filter.Separator] are silently skipped.
     * - [Filter.Group] recurses into its sub-filter list.
     * - Any parse error, missing key, type mismatch, or out-of-range index is
     *   silently skipped — this method never throws.
     */
    fun applySelectionJson(list: FilterList, selectionJson: String) {
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
    private fun applyElement(filter: Filter<*>, elem: JSONObject) {
        when (filter) {
            is Filter.Header, is Filter.Separator -> return

            is Filter.Select<*> -> runCatching {
                (filter as Filter<Int>).state = elem.getInt("state")
            }

            is Filter.Text -> runCatching {
                filter.state = elem.getString("state")
            }

            is Filter.CheckBox -> runCatching {
                filter.state = elem.getBoolean("state")
            }

            is Filter.TriState -> runCatching {
                (filter as Filter<Int>).state = elem.getInt("state")
            }

            is Filter.Sort -> runCatching {
                val stateRaw = elem.opt("state")
                if (stateRaw != null && stateRaw !== JSONObject.NULL) {
                    val stateObj = elem.getJSONObject("state")
                    filter.state = Filter.Sort.Selection(
                        stateObj.getInt("index"),
                        stateObj.getBoolean("ascending"),
                    )
                }
                // null state: leave/clear — do nothing (contract: "if null, leave/clear")
            }

            is Filter.Group<*> -> runCatching {
                val subFiltersJson = elem.getJSONArray("filters")
                val subFilters = filter.state as List<Filter<*>>
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
