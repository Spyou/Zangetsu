package com.spyou.watch_app.aniyomi

import eu.kanade.tachiyomi.animesource.model.AnimeFilter
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AniyomiFilterJsonTest {

    // -------------------------------------------------------------------------
    // Concrete test subclasses of the abstract filter types
    // -------------------------------------------------------------------------

    private class TestSelect(name: String, values: Array<String>, state: Int = 0)
        : AnimeFilter.Select<String>(name, values, state)

    private class TestTriState(name: String, state: Int = AnimeFilter.TriState.STATE_IGNORE)
        : AnimeFilter.TriState(name, state)

    private class TestSort(
        name: String,
        values: Array<String>,
        state: Selection? = null,
    ) : AnimeFilter.Sort(name, values, state)

    private class TestCheckBox(name: String, state: Boolean = false)
        : AnimeFilter.CheckBox(name, state)

    private class TestText(name: String, state: String = "")
        : AnimeFilter.Text(name, state)

    private class TestGroup(name: String, state: List<AnimeFilter<*>>)
        : AnimeFilter.Group<AnimeFilter<*>>(name, state)

    // -------------------------------------------------------------------------
    // Helpers to build the canonical test filter list
    // -------------------------------------------------------------------------

    private fun makeList(): Pair<AnimeFilterList, Map<String, AnimeFilter<*>>> {
        val header  = AnimeFilter.Header("Sort & Filter")
        val select  = TestSelect("Genre", arrayOf("All", "Action", "Comedy"), 0)
        val sort    = TestSort("Sort By", arrayOf("Popularity", "Rating"),
            AnimeFilter.Sort.Selection(0, true))
        val tristate = TestTriState("Subtitles", AnimeFilter.TriState.STATE_IGNORE)
        val cb1     = TestCheckBox("SubA", false)
        val cb2     = TestCheckBox("SubB", true)
        val group   = TestGroup("Categories", listOf(cb1, cb2))
        val list    = AnimeFilterList(header, select, sort, tristate, group)
        return list to mapOf(
            "header"   to header,
            "select"   to select,
            "sort"     to sort,
            "tristate" to tristate,
            "cb1"      to cb1,
            "cb2"      to cb2,
            "group"    to group,
        )
    }

    // -------------------------------------------------------------------------
    // Test 1 — filterListToJson: correct ordered types and field shapes
    // -------------------------------------------------------------------------

    @Test
    fun filterListToJson_emits_ordered_elements_with_correct_types() {
        val (list, _) = makeList()
        val json = AniyomiFilterJson.filterListToJson(list)
        val arr  = JSONArray(json)

        assertEquals("array length", 5, arr.length())

        // [0] header
        val h = arr.getJSONObject(0)
        assertEquals("header", h.getString("type"))
        assertEquals("Sort & Filter", h.getString("name"))
        assertFalse("header has no state", h.has("state"))

        // [1] select
        val s = arr.getJSONObject(1)
        assertEquals("select", s.getString("type"))
        assertEquals("Genre", s.getString("name"))
        assertEquals(0, s.getInt("state"))
        val vals = s.getJSONArray("values")
        assertEquals(3, vals.length())
        assertEquals("All",    vals.getString(0))
        assertEquals("Action", vals.getString(1))
        assertEquals("Comedy", vals.getString(2))

        // [2] sort — state is an object with index + ascending
        val so = arr.getJSONObject(2)
        assertEquals("sort", so.getString("type"))
        assertEquals("Sort By", so.getString("name"))
        val vals2 = so.getJSONArray("values")
        assertEquals(2, vals2.length())
        assertEquals("Popularity", vals2.getString(0))
        assertEquals("Rating",     vals2.getString(1))
        val sortState = so.getJSONObject("state")
        assertEquals(0, sortState.getInt("index"))
        assertTrue(sortState.getBoolean("ascending"))

        // [3] tristate
        val ts = arr.getJSONObject(3)
        assertEquals("tristate", ts.getString("type"))
        assertEquals("Subtitles", ts.getString("name"))
        assertEquals(AnimeFilter.TriState.STATE_IGNORE, ts.getInt("state"))

        // [4] group — has "filters" array, no direct state
        val g = arr.getJSONObject(4)
        assertEquals("group", g.getString("type"))
        assertEquals("Categories", g.getString("name"))
        assertFalse("group has no state key", g.has("state"))
        val filters = g.getJSONArray("filters")
        assertEquals(2, filters.length())
        val f0 = filters.getJSONObject(0)
        assertEquals("checkbox", f0.getString("type"))
        assertEquals("SubA", f0.getString("name"))
        assertFalse(f0.getBoolean("state"))
        val f1 = filters.getJSONObject(1)
        assertEquals("checkbox", f1.getString("type"))
        assertEquals("SubB", f1.getString("name"))
        assertTrue(f1.getBoolean("state"))
    }

    @Test
    fun filterListToJson_sort_with_null_state_emits_json_null() {
        val sort = TestSort("Sort", arrayOf("A", "B"), null)
        val list = AnimeFilterList(sort)
        val arr  = JSONArray(AniyomiFilterJson.filterListToJson(list))
        val so   = arr.getJSONObject(0)
        assertTrue("state should be JSON null when Selection is null", so.isNull("state"))
    }

    @Test
    fun filterListToJson_text_filter() {
        val text = TestText("Search", "hello")
        val list = AnimeFilterList(text)
        val arr  = JSONArray(AniyomiFilterJson.filterListToJson(list))
        val t    = arr.getJSONObject(0)
        assertEquals("text", t.getString("type"))
        assertEquals("hello", t.getString("state"))
    }

    // -------------------------------------------------------------------------
    // Test 2 — applySelectionJson: mutates the live list in place
    // -------------------------------------------------------------------------

    @Test
    fun applySelectionJson_mutates_filters_in_place() {
        val (list, refs) = makeList()
        val select   = refs["select"]   as TestSelect
        val sort     = refs["sort"]     as TestSort
        val tristate = refs["tristate"] as TestTriState
        val cb1      = refs["cb1"]      as TestCheckBox
        val cb2      = refs["cb2"]      as TestCheckBox

        // Build a modified selection JSON that mirrors the same positions:
        //   [0] header  — skip
        //   [1] select  — change index to 2
        //   [2] sort    — change to {index:1, ascending:false}
        //   [3] tristate — change to EXCLUDE (2)
        //   [4] group   — toggle: cb1 true, cb2 false
        val selectionArr = JSONArray().apply {
            put(JSONObject().put("type", "header").put("name", "Sort & Filter"))
            put(JSONObject().put("type", "select").put("state", 2))
            put(JSONObject().put("type", "sort").put("state",
                JSONObject().put("index", 1).put("ascending", false)))
            put(JSONObject().put("type", "tristate").put("state", AnimeFilter.TriState.STATE_EXCLUDE))
            put(JSONObject().put("type", "group").put("filters", JSONArray().apply {
                put(JSONObject().put("type", "checkbox").put("state", true))
                put(JSONObject().put("type", "checkbox").put("state", false))
            }))
        }

        AniyomiFilterJson.applySelectionJson(list, selectionArr.toString())

        assertEquals("select state mutated", 2, select.state)
        val sortSel = sort.state
        assertEquals("sort index mutated", 1, sortSel!!.index)
        assertFalse("sort ascending mutated", sortSel.ascending)
        assertEquals("tristate mutated to EXCLUDE", AnimeFilter.TriState.STATE_EXCLUDE, tristate.state)
        assertTrue("cb1 toggled to true", cb1.state)
        assertFalse("cb2 toggled to false", cb2.state)
    }

    @Test
    fun applySelectionJson_sort_json_null_leaves_state_unchanged() {
        val sort = TestSort("Sort", arrayOf("A", "B"), AnimeFilter.Sort.Selection(0, true))
        val list = AnimeFilterList(sort)

        // Sending JSON null state for sort: the implementation leaves the existing Selection in place.
        val selectionArr = JSONArray().apply {
            put(JSONObject().put("type", "sort").put("state", JSONObject.NULL))
        }
        AniyomiFilterJson.applySelectionJson(list, selectionArr.toString())
        assertEquals("sort state must be unchanged after JSON null", AnimeFilter.Sort.Selection(0, true), sort.state)
    }

    // -------------------------------------------------------------------------
    // Test 3 — defensive: bad selection JSON does not throw; untouched positions unchanged
    // -------------------------------------------------------------------------

    @Test
    fun applySelectionJson_too_short_array_leaves_untouched_positions_unchanged() {
        val (list, refs) = makeList()
        val sort     = refs["sort"]     as TestSort
        val tristate = refs["tristate"] as TestTriState

        // Only provide selections for positions 0 and 1 — positions 2..4 must be unchanged
        val shortArr = JSONArray().apply {
            put(JSONObject().put("type", "header"))
            put(JSONObject().put("type", "select").put("state", 1))
        }
        AniyomiFilterJson.applySelectionJson(list, shortArr.toString())

        // sort and tristate must be unchanged
        val sortSel = sort.state
        assertEquals("sort index unchanged", 0, sortSel!!.index)
        assertTrue("sort ascending unchanged", sortSel.ascending)
        assertEquals("tristate unchanged", AnimeFilter.TriState.STATE_IGNORE, tristate.state)
    }

    @Test
    fun applySelectionJson_malformed_json_string_does_not_throw() {
        val (list, _) = makeList()
        // Should not throw even with garbage input
        AniyomiFilterJson.applySelectionJson(list, "not valid json {{{{")
    }

    @Test
    fun applySelectionJson_type_mismatch_is_skipped_without_throw() {
        val (list, refs) = makeList()
        val select = refs["select"] as TestSelect
        val originalState = select.state

        // Give select a string state instead of an int — must skip, not throw
        val badArr = JSONArray().apply {
            put(JSONObject().put("type", "header"))
            put(JSONObject().put("type", "select").put("state", "not-an-int"))
        }
        AniyomiFilterJson.applySelectionJson(list, badArr.toString())

        assertEquals("select state unchanged after type mismatch", originalState, select.state)
    }

    @Test
    fun applySelectionJson_empty_array_does_not_throw() {
        val (list, _) = makeList()
        AniyomiFilterJson.applySelectionJson(list, "[]")
    }

    // -------------------------------------------------------------------------
    // Test — round-trip: serialize then apply own output leaves state unchanged
    // -------------------------------------------------------------------------

    @Test
    fun round_trip_serialize_then_apply_preserves_state() {
        val (list, refs) = makeList()
        val select   = refs["select"]   as TestSelect
        val sort     = refs["sort"]     as TestSort
        val tristate = refs["tristate"] as TestTriState

        val json = AniyomiFilterJson.filterListToJson(list)
        AniyomiFilterJson.applySelectionJson(list, json)

        assertEquals("select unchanged after round-trip", 0, select.state)
        assertEquals("tristate unchanged after round-trip",
            AnimeFilter.TriState.STATE_IGNORE, tristate.state)
        val sortSel = sort.state
        assertEquals("sort index unchanged", 0, sortSel!!.index)
        assertTrue("sort ascending unchanged", sortSel.ascending)
    }
}
