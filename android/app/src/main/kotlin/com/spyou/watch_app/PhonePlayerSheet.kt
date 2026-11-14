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

    fun setTrackItems(labels: Array<String>, audioStart: Int, subtitleStart: Int,
                      selected: Set<Int>, listener: DialogInterface.OnClickListener): PhonePlayerSheet = apply {
        val content = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        fun addRows(parent: LinearLayout, range: IntRange) {
            for (index in range) {
                parent.addView(label(labels[index].substringAfter(": ").removeSuffix(" ✓"), index in selected).apply {
                    foreground = ripple()
                    setOnClickListener { dialog?.let { listener.onClick(it, index); it.dismiss() } }
                }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(3); bottomMargin = dp(3) })
            }
        }
        addRows(content, 0 until audioStart)
        val columns = LinearLayout(context)
        for ((title, range) in listOf(
            R.string.phone_player_watch_audio to (audioStart until subtitleStart),
            R.string.phone_player_title_subtitles to (subtitleStart until labels.size),
        )) {
            val column = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
            column.addView(label(context.getText(title)).apply {
                textSize = 13f
                setTextColor(secondary)
                setTypeface(typeface, Typeface.BOLD)
            })
            addRows(column, range)
            columns.addView(column, LinearLayout.LayoutParams(0, -2, 1f))
        }
        content.addView(columns)
        scroll(content)
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
        val cap = ((metrics.heightPixels - (insets?.top ?: 0) - bottom) * 0.6f).toInt()
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
