package com.spyou.watch_app

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.DialogInterface
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.BaseAdapter
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/** Phone-only menu surfaces; selection callbacks still belong to the player. */
internal class PhonePlayerSheet(context: Context) : AlertDialog.Builder(context, R.style.PhonePlayerDialog) {
    private val activity = context as Activity
    private val accent = activity.intent.getIntExtra(PhonePlayerIntent.EXTRA_ACCENT,
        context.getColor(R.color.phone_player_accent))
    private var heading: CharSequence? = null
    private var dialog: AlertDialog? = null
    private var body: ScrollView? = null
    private var icons: List<Int> = emptyList()
    private val surface = 0xFF16161C.toInt()
    private val secondary = 0xFFA7A7B2.toInt()

    /** The tallest a sheet may be: [share] of what the bars leave on screen. */
    private fun capPx(share: Float = 0.6f): Int {
        val insets = ViewCompat.getRootWindowInsets(activity.window.decorView)
            ?.getInsets(WindowInsetsCompat.Type.systemBars())
        val bottom = (insets?.bottom ?: 0) + dp(12)
        return ((context.resources.displayMetrics.heightPixels - (insets?.top ?: 0) - bottom) * share).toInt()
    }

    private fun dp(value: Int) = (value * context.resources.displayMetrics.density + 0.5f).toInt()
    private fun shape(color: Int, radius: Int = 10) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
    }

    private fun ripple(radius: Int = 10) = RippleDrawable(
        ColorStateList.valueOf(0x1AFFFFFF), null, shape(Color.WHITE, radius),
    )

    override fun setTitle(title: CharSequence?): PhonePlayerSheet = apply { heading = title }
    override fun setTitle(titleId: Int): PhonePlayerSheet = setTitle(context.getText(titleId))

    fun setItemIcons(values: List<Int>): PhonePlayerSheet = apply { icons = values }

    override fun setItems(items: Array<out CharSequence>?, listener: DialogInterface.OnClickListener?): PhonePlayerSheet = apply {
        super.setAdapter(itemsAdapter(items.orEmpty()), listener)
    }

    override fun setSingleChoiceItems(items: Array<out CharSequence>?, checkedItem: Int,
                                      listener: DialogInterface.OnClickListener?): PhonePlayerSheet = apply {
        super.setSingleChoiceItems(itemsAdapter(items.orEmpty()), checkedItem, listener)
    }

    private fun itemsAdapter(items: Array<out CharSequence>) = object : BaseAdapter() {
        override fun getCount() = items.size
        override fun getItem(position: Int) = items[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val active = position == (parent as android.widget.ListView).checkedItemPosition
            val row = convertView as? LinearLayout ?: LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL
                foreground = ripple()
                if (icons.isNotEmpty()) {
                    addView(ImageView(context).apply {
                        setColorFilter(secondary)
                    }, LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginStart = dp(12) })
                }
                addView(label(""), LinearLayout.LayoutParams(0, -2, 1f))
            }
            row.isSelected = active
            val text = row.getChildAt(row.childCount - 1) as TextView
            bindLabel(text, getItem(position).toString(), active)
            row.background = text.background
            text.background = null
            icons.getOrNull(position)?.let { (row.getChildAt(0) as ImageView).setImageResource(it) }
            return row
        }
    }

    private fun label(text: CharSequence, selected: Boolean = false): TextView = TextView(context).apply {
        textSize = 14f
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(48)
        setPadding(dp(12), dp(13), dp(12), dp(13))
        bindLabel(this, text, selected)
    }

    private fun bindLabel(view: TextView, text: CharSequence, selected: Boolean) = with(view) {
        this.text = text
        setTextColor(if (selected) accent else Color.WHITE)
        setTypeface(typeface, if (selected) Typeface.BOLD else Typeface.NORMAL)
        isSelected = selected
        background = shape(if (selected) (accent and 0x00FFFFFF) or 0x26000000 else Color.TRANSPARENT)
        setCompoundDrawablesRelativeWithIntrinsicBounds(null, null, null, null)
        if (selected) {
            val check = context.getDrawable(R.drawable.phone_player_check)!!.mutate()
            check.setTint(accent)
            setCompoundDrawablesRelativeWithIntrinsicBounds(null, null, check, null)
            compoundDrawablePadding = dp(8)
        }
    }

    private fun scroll(content: View) {
        body = ScrollView(context).apply {
            isFillViewport = false
            setPadding(dp(12), 0, dp(12), dp(12))
            addView(content)
        }
        setView(body)
    }

    fun setChips(labels: Array<String>, selected: Int,
                 listener: DialogInterface.OnClickListener): PhonePlayerSheet = apply {
        val widthDp = context.resources.displayMetrics.run { widthPixels / density }.coerceAtMost(560f)
        val grid = GridLayout(context).apply { columnCount = if (widthDp >= 480) 5 else 3 }
        for ((index, text) in labels.withIndex()) {
            val chip = label(text, index == selected).apply {
                gravity = Gravity.CENTER
                setTextColor(if (isSelected) Color.WHITE else secondary)
                setCompoundDrawables(null, null, null, null)
                background = shape(if (isSelected) accent else Color.TRANSPARENT, 32).apply {
                    if (!isSelected) setStroke(dp(1), 0x29FFFFFF)
                }
                foreground = ripple(32)
                setOnClickListener { dialog?.let { listener.onClick(it, index) } }
            }
            grid.addView(chip, GridLayout.LayoutParams().apply {
                width = 0
                columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f)
                setMargins(dp(4), dp(4), dp(4), dp(4))
            })
        }
        scroll(grid)
    }

    /** One line in the Audio & subtitles sheet. */
    internal class SheetRow(
        val label: String,
        val detail: String? = null,
        val selected: Boolean = false,
        val icon: Int? = null,
        val onClick: () -> Unit,
    )

    /** A scroll area that never grows past [maxPx]. */
    private class CappedScroll(context: Context, private val maxPx: Int) : ScrollView(context) {
        init {
            // Rows are tapped, never focused; focus would scroll the list on open.
            isFocusable = false
            isFocusableInTouchMode = false
            descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
        }

        override fun onMeasure(widthSpec: Int, heightSpec: Int) = super.onMeasure(
            widthSpec, View.MeasureSpec.makeMeasureSpec(maxPx, View.MeasureSpec.AT_MOST),
        )
    }

    private fun sheetRow(row: SheetRow, close: () -> Unit): View {
        val line = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(48)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            background = shape(if (row.selected) (accent and 0x00FFFFFF) or 0x26000000 else Color.TRANSPARENT)
            foreground = ripple()
            setOnClickListener { close(); row.onClick() }
        }
        row.icon?.let {
            line.addView(ImageView(context).apply {
                setImageResource(it)
                setColorFilter(secondary)
            }, LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginEnd = dp(12) })
        }
        val text = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        text.addView(TextView(context).apply {
            textSize = 14f
            this.text = row.label
            setTextColor(if (row.selected) accent else Color.WHITE)
            setTypeface(typeface, if (row.selected) Typeface.BOLD else Typeface.NORMAL)
        })
        row.detail?.let { detail ->
            text.addView(TextView(context).apply {
                textSize = 12f
                this.text = detail
                setTextColor(secondary)
            })
        }
        line.addView(text, LinearLayout.LayoutParams(0, -2, 1f))
        if (row.selected) {
            line.addView(ImageView(context).apply {
                setImageDrawable(context.getDrawable(R.drawable.phone_player_check)!!.mutate().also { it.setTint(accent) })
            }, LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginStart = dp(8) })
        }
        return line
    }

    /**
     * The Audio & subtitles sheet, laid out like the MPV player's: Audio and
     * Subtitles side by side (each scrolls on its own), then a divider and the
     * settings rows underneath.
     */
    fun setAudioSubtitleSheet(audio: List<SheetRow>, subtitles: List<SheetRow>, footer: List<SheetRow>): PhonePlayerSheet = apply {
        val content = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        fun close() { dialog?.dismiss() }
        // The columns take whatever the sheet has left after its footer, so the
        // sheet as a whole fits without a second, competing scroll.
        val footerPx = if (footer.isEmpty()) 0 else dp(92)
        val cap = (capPx(0.85f) - footerPx - dp(110)).coerceAtLeast(dp(96))
        val columns = LinearLayout(context)
        val sections = listOf(
            context.getText(R.string.phone_player_watch_audio) to audio,
            context.getText(R.string.phone_player_title_subtitles) to subtitles,
        )
        for ((index, section) in sections.withIndex()) {
            val (title, rows) = section
            val column = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
            column.addView(label(title).apply {
                textSize = 13f
                setTextColor(secondary)
                setTypeface(typeface, Typeface.BOLD)
            })
            val list = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
            var current: View? = null
            for (row in rows) {
                val view = sheetRow(row, ::close)
                if (row.selected && current == null) current = view
                list.addView(view, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(2); bottomMargin = dp(2) })
            }
            column.addView(CappedScroll(context, cap).apply {
                addView(list)
                // Open at the top, or at the playing track when it sits far down.
                post { scrollTo(0, ((current?.top ?: 0) - dp(56)).coerceAtLeast(0)) }
            })
            if (index == 1) columns.addView(View(context).apply { setBackgroundColor(0x14FFFFFF) },
                LinearLayout.LayoutParams(dp(1), -1).apply { setMargins(dp(4), dp(8), dp(4), dp(8)) })
            columns.addView(column, LinearLayout.LayoutParams(0, -2, 1f))
        }
        content.addView(columns)
        if (footer.isNotEmpty()) {
            content.addView(View(context).apply { setBackgroundColor(0x14FFFFFF) },
                LinearLayout.LayoutParams(-1, dp(1)).apply { setMargins(dp(4), dp(10), dp(4), dp(6)) })
            // Actions in one row, icon over label, so three fit side by side.
            val actions = LinearLayout(context)
            for (row in footer) {
                val action = LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER
                    minimumHeight = dp(64)
                    setPadding(dp(4), dp(8), dp(4), dp(8))
                    background = shape(Color.TRANSPARENT)
                    foreground = ripple()
                    setOnClickListener { close(); row.onClick() }
                }
                row.icon?.let {
                    action.addView(ImageView(context).apply {
                        setImageResource(it)
                        setColorFilter(secondary)
                    }, LinearLayout.LayoutParams(dp(22), dp(22)))
                }
                action.addView(TextView(context).apply {
                    textSize = 12f
                    gravity = Gravity.CENTER
                    text = row.label
                    setTextColor(Color.WHITE)
                }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(4) })
                actions.addView(action, LinearLayout.LayoutParams(0, -2, 1f))
            }
            content.addView(actions, LinearLayout.LayoutParams(-1, -2))
        }
        // No outer scroll view: the two lists scroll on their own, and a second
        // scroller around them would fight for the same swipe.
        content.setPadding(dp(12), 0, dp(12), dp(12))
        setView(content)
    }

    override fun create(): AlertDialog {
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(10), dp(20), dp(8))
            addView(View(context).apply { background = shape(0xFF20212A.toInt(), 2) },
                LinearLayout.LayoutParams(dp(36), dp(4)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(14) })
            heading?.let { title ->
                addView(TextView(context).apply {
                    text = title
                    textSize = 17f
                    setTextColor(Color.WHITE)
                    setTypeface(typeface, Typeface.BOLD)
                })
            }
        }
        setCustomTitle(header)
        return super.create().also { created ->
            dialog = created
            body?.let { created.setView(it, 0, 0, 0, 0) }
        }
    }

    override fun show(): AlertDialog = super.show().also { style(it) }

    private fun style(shown: AlertDialog) {
        val window = shown.window ?: return
        val metrics = context.resources.displayMetrics
        val insets = ViewCompat.getRootWindowInsets(activity.window.decorView)
            ?.getInsets(WindowInsetsCompat.Type.systemBars())
        val bottom = (insets?.bottom ?: 0) + dp(12)
        val width = minOf(metrics.widthPixels, dp(580))
        val cap = capPx()
        window.setBackgroundDrawable(InsetDrawable(shape(surface, 24).apply { setStroke(dp(1), 0x14FFFFFF) },
            dp(10), 0, dp(10), bottom))
        window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.setDimAmount(0.54f)
        window.setGravity(Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL)
        window.setLayout(width, WindowManager.LayoutParams.WRAP_CONTENT)
        window.decorView.systemUiVisibility = activity.window.decorView.systemUiVisibility
        for (button in listOf(DialogInterface.BUTTON_POSITIVE, DialogInterface.BUTTON_NEGATIVE, DialogInterface.BUTTON_NEUTRAL)) {
            shown.getButton(button)?.setTextColor(accent)
        }
        body?.let {
            it.measure(View.MeasureSpec.makeMeasureSpec(width - dp(44), View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(cap, View.MeasureSpec.AT_MOST))
            if (it.measuredHeight >= cap) it.layoutParams = it.layoutParams.apply { height = cap }
        }
        val list = shown.listView ?: return
        list.divider = null
        list.selector = ColorDrawable(Color.TRANSPARENT)
        list.setPadding(dp(12), 0, dp(12), dp(12))
        list.clipToPadding = false
        var height = 0
        for (index in 0 until list.count) {
            val row = list.adapter.getView(index, null, list)
            row.measure(View.MeasureSpec.makeMeasureSpec(width - dp(44), View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
            height += row.measuredHeight
            if (height >= cap) break
        }
        list.layoutParams = list.layoutParams.apply { this.height = minOf(height + dp(12), cap) }
    }
}
