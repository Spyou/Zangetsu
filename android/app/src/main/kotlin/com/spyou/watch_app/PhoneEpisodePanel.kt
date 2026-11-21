package com.spyou.watch_app

import android.app.Dialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.widget.*
import androidx.core.widget.doAfterTextChanged

internal class PhoneEpisodePanel(
    context: Context,
    private val episodes: List<PhoneWatchEpisode>,
    private val currentIndex: Int,
    private val cover: String,
    headers: Map<String, String>,
    private val accent: Int,
    private val onEpisode: (Int) -> Unit,
) : Dialog(context, R.style.PhonePlayerDialog) {
    private val images = PhoneWatchImages(context, headers)
    private val secondary = 0xFFBDBDC6.toInt()
    private val seasons = episodes.map { it.season ?: 1 }.distinct().sorted()
    private var shown = episodes
    private var query = ""
    private var reversed = false
    private val list = ListView(context)
    private val adapter = object : BaseAdapter() {
        override fun getCount() = shown.size
        override fun getItem(position: Int) = shown[position]
        override fun getItemId(position: Int) = getItem(position).index.toLong()
        override fun hasStableIds() = true
        override fun getView(position: Int, recycled: View?, parent: ViewGroup): View {
            val row = recycled as? EpisodeRow ?: EpisodeRow()
            val episode = getItem(position)
            val season = episode.season ?: 1
            val startsSeason = seasons.size > 1 &&
                (position == 0 || (getItem(position - 1).season ?: 1) != season)
            row.bind(episode, season.takeIf { startsSeason })
            return row
        }
    }

    init {
        val panel = column().apply {
            isFocusableInTouchMode = true
            background = shape(0xF21C1C22.toInt(), 20, leftOnly = true)
        }
        val header = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(5), dp(4), dp(3))
            addView(text(17f).apply {
                text = context.getString(R.string.phone_player_watch_count, episodes.size)
                setTypeface(typeface, Typeface.BOLD)
            }, LinearLayout.LayoutParams(0, -2, 1f))
            if (seasons.size > 1) {
                val currentSeason = episodes.getOrNull(currentIndex)?.season ?: 1
                addView(action("S$currentSeason ⌄", context.getString(R.string.phone_player_episode_panel_season)) {
                    val anchor = it as TextView
                    PopupMenu(context, anchor).apply {
                        seasons.forEach { season ->
                            menu.add(0, season, 0, context.getString(R.string.phone_player_watch_season, season))
                        }
                        setOnMenuItemClickListener { item ->
                            val position = shown.indexOfFirst { (it.season ?: 1) == item.itemId }
                            if (position >= 0) {
                                anchor.text = "S${item.itemId} ⌄"
                                list.smoothScrollToPositionFromTop(position, 0)
                            }
                            true
                        }
                    }.show()
                }, LinearLayout.LayoutParams(dp(52), dp(48)))
            }
            addView(action("×", context.getString(android.R.string.cancel)) { dismiss() },
                LinearLayout.LayoutParams(dp(48), dp(48)))
        }
        panel.addView(header)
        if (episodes.size >= 8) {
            panel.addView(LinearLayout(context).apply {
                setPadding(dp(12), 0, dp(12), dp(8))
                addView(EditText(context).apply {
                    id = android.R.id.edit
                    hint = context.getString(R.string.phone_player_watch_search)
                    setSingleLine(true)
                    textSize = 14f
                    setTextColor(Color.WHITE)
                    setHintTextColor(secondary)
                    background = shape(0xFF292930.toInt(), 9)
                    setPadding(dp(10), 0, dp(10), 0)
                    doAfterTextChanged {
                        query = it.toString().trim()
                        refresh()
                    }
                }, LinearLayout.LayoutParams(0, dp(48), 1f))
                addView(action("↑", context.getString(R.string.phone_player_watch_reverse)) {
                    reversed = !reversed
                    (it as TextView).text = if (reversed) "↓" else "↑"
                    refresh()
                }, LinearLayout.LayoutParams(dp(48), dp(48)).apply { marginStart = dp(8) })
            })
        }
        list.apply {
            id = android.R.id.list
            divider = null
            choiceMode = ListView.CHOICE_MODE_SINGLE
            adapter = this@PhoneEpisodePanel.adapter
            setOnItemClickListener { _, _, position, _ ->
                val index = shown[position].index
                dismiss()
                if (index != currentIndex) onEpisode(index)
            }
        }
        panel.addView(list, LinearLayout.LayoutParams(-1, 0, 1f))
        val empty = text(14f, secondary).apply {
            text = context.getString(R.string.phone_player_watch_no_match)
            gravity = Gravity.CENTER
        }
        panel.addView(empty, LinearLayout.LayoutParams(-1, 0, 1f))
        list.emptyView = empty
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        setContentView(panel)
        setCanceledOnTouchOutside(true)
        panel.requestFocus()
        window?.apply {
            setBackgroundDrawableResource(android.R.color.transparent)
            setGravity(Gravity.RIGHT)
            addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            setDimAmount(0.54f)
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN or
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            setWindowAnimations(R.style.PhoneEpisodePanelAnimation)
        }
        refresh()
        list.setSelectionFromTop((shown.indexOfFirst { it.index == currentIndex } - 1).coerceAtLeast(0), 0)
    }

    override fun onStart() {
        super.onStart()
        val width = context.resources.displayMetrics.widthPixels
        window?.setLayout((width * 0.33f).toInt().coerceIn(dp(250), dp(360)).coerceAtMost(width), -1)
    }

    override fun onStop() {
        images.close()
        super.onStop()
    }

    private fun refresh() {
        val matches = episodes.filter {
            val number = it.number?.toInt() ?: (it.index + 1)
            number.toString().startsWith(query) || it.heading.contains(query, ignoreCase = true)
        }
        val ordered = if (seasons.size > 1) matches.sortedBy { it.season ?: 1 } else matches
        shown = if (reversed) ordered.asReversed() else ordered
        list.clearChoices()
        adapter.notifyDataSetChanged()
        val selected = shown.indexOfFirst { it.index == currentIndex }
        if (selected >= 0) list.setItemChecked(selected, true)
    }

    private inner class EpisodeRow : LinearLayout(this@PhoneEpisodePanel.context) {
        private val season = text(11f, secondary).apply {
            setPadding(dp(14), dp(8), dp(12), dp(4))
        }
        private val thumb = ImageView(context).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = shape(0xFF292930.toInt(), 7)
            clipToOutline = true
        }
        private val title = text(14f)
        private val meta = text(12f, secondary)
        private val card = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(65)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            addView(thumb, LayoutParams(dp(80), dp(45)))
            addView(column().apply {
                setPadding(dp(10), 0, 0, 0)
                addView(title)
                addView(meta)
            }, LayoutParams(0, -2, 1f))
        }

        init {
            orientation = VERTICAL
            addView(season)
            addView(card, LayoutParams(-1, -2))
        }

        fun bind(episode: PhoneWatchEpisode, section: Int?) {
            season.visibility = if (section == null) View.GONE else View.VISIBLE
            if (section != null) season.text = context.getString(R.string.phone_player_watch_season, section)
            val playing = episode.index == currentIndex
            title.text = episode.heading
            title.setTextColor(if (playing) accent else Color.WHITE)
            meta.text = if (playing) context.getString(R.string.phone_player_episode_panel_playing) else episode.meta
            meta.visibility = if (meta.text.isEmpty()) View.GONE else View.VISIBLE
            card.setBackgroundColor(if (playing) (accent and 0x00FFFFFF) or 0x28000000 else Color.TRANSPARENT)
            images.load(thumb, episode.thumb.ifBlank { cover })
        }
    }

    private fun dp(value: Int) = (value * context.resources.displayMetrics.density + .5f).toInt()
    private fun column() = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private fun text(size: Float, color: Int = Color.WHITE) = TextView(context).apply {
        textSize = size
        setTextColor(color)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }
    private fun action(label: String, description: String, click: (View) -> Unit) = text(19f, secondary).apply {
        text = label
        gravity = Gravity.CENTER
        contentDescription = description
        isFocusable = true
        background = RippleDrawable(ColorStateList.valueOf(0x25FFFFFF),
            shape(0xFF292930.toInt(), 9), null)
        setOnClickListener(click)
    }
    private fun shape(color: Int, radius: Int, leftOnly: Boolean = false) = GradientDrawable().apply {
        setColor(color)
        val r = dp(radius).toFloat()
        if (leftOnly) cornerRadii = floatArrayOf(r, r, 0f, 0f, 0f, 0f, r, r)
        else cornerRadius = r
    }
}
