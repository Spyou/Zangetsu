package com.spyou.watch_app

/** Keeps unsupported engine controls in the saved layout without drawing fake actions. */
internal data class PhonePlayerControlLayout(
    val top: List<String> = listOf("cast", "info"),
    val left: List<String> = listOf("speed", "tracks", "quality", "sources", "more"),
    val right: List<String> = listOf("episodes", "rotate", "fit"),
) {
    fun asMap() = mapOf("top" to top, "left" to left, "right" to right)

    fun move(id: String, slot: String): PhonePlayerControlLayout? {
        if (slot !in listOf("top", "left", "right", "hidden")) return null
        val lists = asMap().mapValues { (_, ids) -> ids.filterNot { it == id }.toMutableList() }
        if (slot == "top" && lists.getValue("top").size >= 5) return null
        if (slot != "hidden") lists.getValue(slot).add(id)
        if (lists.values.none { "more" in it }) lists.getValue("left").add("more")
        return PhonePlayerControlLayout(lists.getValue("top"), lists.getValue("left"), lists.getValue("right"))
    }

    companion object {
        val iconCodePoints = mapOf(
            "search" to 0xf013d, "grid" to 0xf7c4, "list" to 0xf028a,
            "server" to 0xefd4, "audio" to 0xf0ed, "moreHorizontal" to 0xf8d9,
            "comments" to 0xf62f, "fullscreen" to 0xf7a6, "subtitles" to 0xf3fd,
            "miniBack" to 0xf570,
            "megaSkip" to 0xf0348,
            "play" to 0xf00a0,
            "pause" to 0xf0056,
            "previous" to 0xf0193,
            "next" to 0xf0192,
            "back" to 0xf572,

            "speed" to 0xf01b5,
            "tracks" to 0xf01ef,
            "quality" to 0xf7e9,
            "sources" to 0xf847,
            "more" to 0xf8dc,
            "episodes" to 0xf488,
            "rotate" to 0xf0134,
            "fit" to 0xf766,
            "cast" to 0xe144,
            "info" to 0xf815,
            "lock" to 0xf887,
            "unlock" to 0xf889,
            "settings" to 0xf0164,
        )

        fun fromJson(raw: String?): PhonePlayerControlLayout {
            if (raw == null) return PhonePlayerControlLayout()
            return runCatching {
                val json = org.json.JSONObject(raw)
                val seen = mutableSetOf<String>()
                fun read(key: String): List<String> {
                    val array = json.getJSONArray(key)
                    return (0 until array.length()).map { array.getString(it) }
                        .filter { it.isNotBlank() && seen.add(it) }
                }
                val result = PhonePlayerControlLayout(read("top").take(5), read("left"), read("right"))
                if (result.asMap().values.none { "more" in it }) result.copy(left = result.left + "more") else result
            }.getOrDefault(PhonePlayerControlLayout())
        }
    }
}
