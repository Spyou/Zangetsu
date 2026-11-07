package com.spyou.watch_app

import android.app.AlertDialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.*
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView

internal data class PhoneWatchEpisode(
    val index: Int, val heading: String, val number: Double?, val season: Int?,
    val thumb: String = "", val meta: String = "", val synopsis: String = "",
    val title: String = "", val subtitle: String = "", val description: String = "",
    val unavailable: String = "", val watched: Boolean = false,
) {
    companion object {
        fun from(data: Map<String, Any?>, labels: Array<String>): List<PhoneWatchEpisode> {
            val raw = data["episodes"] as? List<*> ?: emptyList<Any>()
            val indexed = raw.filterIsInstance<Map<*, *>>().associateBy { (it["index"] as? Number)?.toInt() }
            return labels.mapIndexed { index, label ->
                val row = indexed[index].orEmpty()
                fun text(key: String) = row[key] as? String ?: ""
                PhoneWatchEpisode(index, text("heading").ifBlank { label },
                    (row["number"] as? Number)?.toDouble(), (row["season"] as? Number)?.toInt(),
                    text("thumb"), text("meta"), text("synopsis"), text("title"), text("subtitle"),
                    text("synopsis"), text("unavailable"), row["watched"] == true)
            }
        }
    }
}

/** Display-only paging keeps row identity separate from its position on screen. */
internal class PhoneWatchPage(
    private val list: RecyclerView,
    data: Map<String, Any?>,
    labels: Array<String>,
    private val accent: Int,
    private val icon: (String) -> android.graphics.drawable.Drawable?,
    private val onEpisode: (Int) -> Unit,
) {
    private val context = list.context
    val header = (LayoutInflater.from(context).inflate(R.layout.phone_watch_info_header, null) as ViewGroup).apply {
        layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    }
    val episodes = PhoneWatchEpisode.from(data, labels)
    var onEpisodeMenu: ((Int) -> Unit)? = null
    var onEpisodeDownload: ((Int) -> Unit)? = null
    private val canDownload = data["canDownload"] == true
    private val watched = episodes.filter { it.watched }.map { it.index }.toMutableSet()
    fun isWatched(index: Int) = index in watched
    fun setWatched(index: Int, value: Boolean) {
        if (value) watched.add(index) else watched.remove(index)
        adapter.notifyDataSetChanged()
    }
    private val surface = (data["surface"] as? Number)?.toInt() ?: 0xFF202024.toInt()
    private val secondary = (data["secondary"] as? Number)?.toInt() ?: 0xFFBDBDC6.toInt()
    private val images = PhoneWatchImages(context,
        (data["coverHeaders"] as? Map<*, *>)?.entries?.mapNotNull { (key, value) ->
            if (key is String && value is String) key to value else null
        }?.toMap().orEmpty())
    private var current = -1
    private var range = 0
    private var reversed = false
    private var grid = false
    private var season: Int? = null
    private var shown = emptyList<PhoneWatchEpisode>()
    private val adapter = EpisodesAdapter()
    private val manager = GridLayoutManager(context, 3).apply {
        spanSizeLookup = object : GridLayoutManager.SpanSizeLookup() {
            override fun getSpanSize(position: Int) = if (position == 0 || !grid) 3 else 1
        }
    }

    init {
        list.layoutManager = manager
        list.adapter = adapter
        list.itemAnimator = null
        for (id in listOf(R.id.watch_description_card, R.id.watch_comments)) {
            header.findViewById<View>(id).background = shape(20, 0x16FFFFFF)
        }
        header.findViewById<TextView>(R.id.watch_see_more).setTextColor(accent)
        val actions = listOf("server", "audio", "subtitles", "moreHorizontal")
        listOf(R.id.watch_action_server, R.id.watch_action_audio, R.id.watch_action_subtitles, R.id.watch_action_more)
            .forEachIndexed { i, id ->
                header.findViewById<Button>(id).apply {
                    background = shape(999, surface)
                    backgroundTintList = null
                    isAllCaps = false
                    textSize = 15f
                    minWidth = 0
                    minHeight = dp(40)
                    minimumHeight = dp(40)
                    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                    setPadding(dp(14), dp(10), dp(14), dp(10))
                    compoundDrawablePadding = dp(6)
                    PhoneWatchMotion.press(this)
                    icon(actions[i])?.mutate()?.let { drawable ->
                        drawable.setBounds(0, 0, dp(18), dp(18))
                        setCompoundDrawablesRelative(drawable, null, null, null)
                    }
                }
            }
        button(R.id.watch_search, "search") { search() }
        button(R.id.watch_grid, "grid") {
            grid = !grid
            header.findViewById<ImageButton>(R.id.watch_grid).apply {
                setImageDrawable(icon(if (grid) "list" else "grid"))
                contentDescription = context.getString(if (grid) R.string.phone_player_watch_list else R.string.phone_player_watch_grid)
            }
            PhoneWatchMotion.viewMode(list) { adapter.notifyDataSetChanged() }
        }
        button(R.id.watch_episode_more, "more") { more() }
        header.findViewById<ImageView>(R.id.watch_comments_icon).apply {
            setImageDrawable(icon("comments")); setColorFilter(accent)
        }
    }

    private fun dp(n: Int) = (n * context.resources.displayMetrics.density + .5f).toInt()
    private fun shape(radius: Int, color: Int) = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(radius).toFloat()
    }
    private fun button(id: Int, glyph: String, action: () -> Unit) {
        header.findViewById<ImageButton>(id).apply {
            background = shape(999, surface)
            setImageDrawable(icon(glyph))
            setOnClickListener { action() }
            PhoneWatchMotion.press(this)
        }
    }
    fun row(index: Int) = episodes.getOrNull(index)
    private fun ordered(): List<PhoneWatchEpisode> {
        val selected = episodes.filter { season == null || (it.season ?: 1) == season }
        return if (reversed) selected.reversed() else selected
    }
    fun update(index: Int) {
        val changed = current != index
        current = index
        if (changed) range = ordered().indexOfFirst { it.index == index }.coerceAtLeast(0) / 50
        rebuild()
    }
    private fun rebuild(previousRange: Int? = null) {
        val ordered = ordered()
        range = range.coerceIn(0, ((ordered.size - 1).coerceAtLeast(0) / 50))
        shown = ordered.drop(range * 50).take(50)
        header.findViewById<TextView>(R.id.watch_episode_count).text = context.getString(R.string.phone_player_watch_count, episodes.size)
        val ranges = header.findViewById<LinearLayout>(R.id.watch_ranges)
        val oldSeasonLabel = (ranges.getChildAt(0) as? TextView)?.text?.toString()
        ranges.removeAllViews()
        val seasons = episodes.map { it.season ?: 1 }.distinct().sorted()
        fun pill(label: String, selected: Boolean, wasSelected: Boolean = selected, seasonLabel: Boolean = false, action: () -> Unit) {
            ranges.addView(TextView(context).apply {
                text = label; textSize = 12f; gravity = Gravity.CENTER
                if (seasonLabel && oldSeasonLabel != null && oldSeasonLabel != label) {
                    text = oldSeasonLabel
                    post { PhoneWatchMotion.text(this, label) }
                }
                setTextColor(if (selected) Color.WHITE else secondary)
                setPadding(dp(12), 0, dp(12), 0)
                val fill = shape(999, if (wasSelected) accent else surface)
                background = fill
                if (previousRange != null && selected != wasSelected) {
                    post { PhoneWatchMotion.color(this, fill, if (wasSelected) accent else surface, if (selected) accent else surface) }
                }
                PhoneWatchMotion.press(this)
                isFocusable = true; setOnClickListener { action() }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(32)).apply { marginEnd = dp(8) })
        }
        if (seasons.size > 1) pill(season?.let { context.getString(R.string.phone_player_watch_season, it) }
            ?: context.getString(R.string.phone_player_watch_all_seasons), false, seasonLabel = true) {
            val choices = listOf(context.getString(R.string.phone_player_watch_all_seasons)) + seasons.map { context.getString(R.string.phone_player_watch_season, it) }
            AlertDialog.Builder(context, R.style.PhonePlayerDialog).setItems(choices.toTypedArray()) { _, which ->
                season = if (which == 0) null else seasons[which - 1]; range = 0; rebuild()
            }.show().also { PhoneWatchMotion.enter(it) }
        }
        if (ordered.size > 50) for (i in 0..((ordered.size - 1) / 50)) {
            pill("${i * 50 + 1}–${minOf((i + 1) * 50, ordered.size)}", i == range, i == (previousRange ?: range)) {
                val old = range; range = i; rebuild(old)
            }
        }
        header.findViewById<View>(R.id.watch_ranges_scroll).visibility = if (ranges.childCount > 0) View.VISIBLE else View.GONE
        adapter.notifyDataSetChanged()
    }
    private fun more() {
        val anchor = header.findViewById<View>(R.id.watch_episode_more)
        val autoplay = header.findViewById<CheckBox>(R.id.watch_autoplay)
        PopupMenu(context, anchor).apply {
            menu.add(0, 1, 0, R.string.phone_player_watch_reverse).apply { isCheckable = true; isChecked = reversed }
            menu.add(0, 2, 1, R.string.phone_player_watch_autoplay).apply { isCheckable = true; isChecked = autoplay.isChecked }
            setOnMenuItemClickListener {
                if (it.itemId == 1) { reversed = !reversed; range = 0; rebuild() }
                else autoplay.isChecked = !autoplay.isChecked
                true
            }
        }.show()
    }
    private fun search() {
        val input = EditText(context).apply {
            id = android.R.id.edit
            hint = context.getString(R.string.phone_player_watch_find_hint)
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
            isSingleLine = true
        }
        AlertDialog.Builder(context, R.style.PhonePlayerDialog).setTitle(R.string.phone_player_watch_search).setView(input)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val number = input.text.toString().trim().toIntOrNull() ?: return@setPositiveButton
                val ordered = ordered()
                val found = ordered.indexOfFirst { it.number?.toInt() == number }
                val target = if (found >= 0) found else number - 1
                if (target !in ordered.indices) {
                    Toast.makeText(context, R.string.phone_player_watch_no_match, Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                range = target / 50
                rebuild()
                manager.scrollToPositionWithOffset(target % 50 + 1, dp(8))
            }.setNegativeButton(android.R.string.cancel, null).show().also { PhoneWatchMotion.enter(it) }
    }
    private fun open(ep: PhoneWatchEpisode) {
        if (ep.unavailable.isEmpty()) onEpisode(ep.index)
        else Toast.makeText(context, ep.unavailable, Toast.LENGTH_SHORT).show()
    }
    private inner class Holder(view: View) : RecyclerView.ViewHolder(view)
    private inner class EpisodesAdapter : RecyclerView.Adapter<Holder>() {
        override fun getItemCount() = shown.size + 1
        override fun getItemViewType(position: Int) = if (position == 0) 0 else if (grid) 2 else 1
        override fun onCreateViewHolder(parent: ViewGroup, type: Int): Holder {
            if (type == 0) return Holder(header)
            val row = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                setPadding(dp(if (type == 2) 4 else 16), dp(10), dp(if (type == 2) 4 else 16), dp(10))
            }
            if (type == 2) {
                row.addView(TextView(context).apply { tag = "number"; gravity = Gravity.CENTER; textSize = 18f },
                    LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(72)))
            } else {
                val line = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
                val art = FrameLayout(context).apply { background = shape(10, surface); clipToOutline = true }
                art.addView(ImageView(context).apply {
                    tag = "thumbnail"; scaleType = ImageView.ScaleType.CENTER_CROP
                }, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                art.addView(ImageView(context).apply {
                    tag = "playing"; setImageDrawable(icon("play"))
                }, FrameLayout.LayoutParams(dp(28), dp(28), Gravity.CENTER))
                line.addView(art, LinearLayout.LayoutParams(dp(116), dp(65)))
                val texts = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(12), 0, 0, 0) }
                texts.addView(TextView(context).apply { tag = "heading"; textSize = 15f; maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END; typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL) })
                texts.addView(TextView(context).apply { tag = "meta"; textSize = 13f; maxLines = 1; setTextColor(secondary) })
                line.addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                line.addView(ImageButton(context).apply {
                    tag = "download"; contentDescription = context.getString(R.string.phone_player_watch_download)
                    foreground = context.getDrawable(R.drawable.phone_player_icon_ripple)
                    background = null; setImageDrawable(icon("download")); setColorFilter(Color.WHITE)
                    setPadding(dp(12), dp(12), dp(12), dp(12))
                }, LinearLayout.LayoutParams(dp(48), dp(48)))
                row.addView(line)
                row.addView(TextView(context).apply { tag = "synopsis"; textSize = 13f; typeface = Typeface.create("sans-serif", Typeface.ITALIC); setLineSpacing(0f, 1.4f); maxLines = 3; ellipsize = android.text.TextUtils.TruncateAt.END; setTextColor(secondary); setPadding(0, dp(6), 0, 0) })
            }
            row.foreground = android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf((accent and 0x00FFFFFF) or 0x24000000),
                null, shape(10, Color.WHITE))
            return Holder(row)
        }
        override fun onBindViewHolder(holder: Holder, position: Int) {
            if (position == 0) return
            val ep = shown[position - 1]
            val root = holder.itemView
            val sameRow = root.tag == ep.index
            root.tag = ep.index
            root.alpha = if (ep.unavailable.isEmpty()) 1f else .55f
            root.contentDescription = ep.heading
            root.isFocusable = true
            root.setOnClickListener { open(ep) }
            root.setOnLongClickListener {
                val menu = onEpisodeMenu
                if (menu == null) false else { menu(ep.index); true }
            }
            root.findViewWithTag<View>("download")?.apply {
                visibility = if (canDownload && onEpisodeDownload != null && ep.unavailable.isEmpty()) View.VISIBLE else View.GONE
                setOnClickListener { onEpisodeDownload?.invoke(ep.index) }
            }
            if (grid) {
                root.findViewWithTag<TextView>("number").apply {
                    text = ep.number?.toInt()?.toString() ?: (ep.index + 1).toString()
                    PhoneWatchMotion.textColor(this, if (ep.index == current) accent else if (isWatched(ep.index)) secondary else Color.WHITE, sameRow)
                    background = shape(12, if (ep.index == current) (accent and 0x00FFFFFF) or 0x29000000 else surface).apply {
                        if (ep.index == this@PhoneWatchPage.current) setStroke(dp(1), accent)
                    }
                }
            } else {
                root.findViewWithTag<TextView>("heading").apply {
                    text = ep.heading
                    PhoneWatchMotion.textColor(this, if (ep.index == current) accent else if (isWatched(ep.index)) secondary else Color.WHITE, sameRow)
                }
                root.findViewWithTag<TextView>("meta").apply { text = ep.meta; visibility = if (ep.meta.isEmpty()) View.GONE else View.VISIBLE }
                root.findViewWithTag<TextView>("synopsis").apply { text = ep.synopsis; visibility = if (ep.synopsis.isEmpty()) View.GONE else View.VISIBLE }
                root.findViewWithTag<ImageView>("playing").apply {
                    setImageDrawable(icon(if (ep.index == current) "play" else "watched"))
                    visibility = if (ep.index == current || isWatched(ep.index)) View.VISIBLE else View.GONE
                }
                images.load(root.findViewWithTag("thumbnail"), ep.thumb)
            }
        }
        override fun onViewRecycled(holder: Holder) {
            holder.itemView.animate().cancel()
            holder.itemView.scaleX = 1f; holder.itemView.scaleY = 1f
            holder.itemView.findViewWithTag<TextView>("heading")?.let { (it.getTag(R.id.watch_color_motion) as? android.animation.ValueAnimator)?.cancel() }
            holder.itemView.findViewWithTag<TextView>("number")?.let { (it.getTag(R.id.watch_color_motion) as? android.animation.ValueAnimator)?.cancel() }
            holder.itemView.findViewWithTag<ImageView>("thumbnail")?.let { images.clear(it) }
        }
    }
    fun close() { images.close(); list.adapter = null }
}
