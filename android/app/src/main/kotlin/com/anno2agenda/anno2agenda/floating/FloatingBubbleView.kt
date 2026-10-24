package com.anno2agenda.anno2agenda.floating

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.MotionEvent
import androidx.appcompat.widget.AppCompatTextView
import kotlin.math.abs

/**
 * 折叠态贴边悬浮胶囊视图 (Floating Bubble View)
 *
 * 仅承担折叠悬浮球 UI 渲染与触控手势探测，通过回调通知上层 Controller，
 * 不直接依赖或调用 AI、OCR 或 CalendarContract。
 */
class FloatingBubbleView(context: Context) : AppCompatTextView(context) {

    var onPillClicked: (() -> Unit)? = null
    var onDragStarted: (() -> Unit)? = null
    var onDragMoved: ((dx: Int, dy: Int, rawX: Float, rawY: Float) -> Unit)? = null
    var onDragReleased: (() -> Unit)? = null

    private var initialTouchX = 0f
    private var initialTouchY = 0f
    private var isDragging = false

    init {
        text = "📅 知程"
        setTextColor(Color.WHITE)
        textSize = 13f
        typeface = Typeface.DEFAULT_BOLD
        val padH = dp(14)
        val padV = dp(9)
        setPadding(padH, padV, padH, padV)
        elevation = dp(8).toFloat()

        applyTheme(isDark = false)
        setupTouchListener()
    }

    /**
     * 跟随主应用深浅色主题切换更新胶囊外观
     */
    fun applyTheme(isDark: Boolean) {
        if (isDark) {
            setTextColor(Color.parseColor("#F8FAFC"))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(24).toFloat()
                setColor(Color.parseColor("#1E40AF"))
                setStroke(dp(2), Color.parseColor("#60A5FA"))
            }
        } else {
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(24).toFloat()
                setColor(Color.parseColor("#2563EB"))
                setStroke(dp(2), Color.parseColor("#93C5FD"))
            }
        }
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    fun setDimmed(dimmed: Boolean) {
        animate()
            .alpha(if (dimmed) 0.65f else 0.96f)
            .setDuration(220)
            .start()
    }

    private fun setupTouchListener() {
        setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    isDragging = false
                    setDimmed(false)
                    onDragStarted?.invoke()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - initialTouchX).toInt()
                    val dy = (event.rawY - initialTouchY).toInt()
                    if (abs(dx) > dp(6) || abs(dy) > dp(6)) {
                        isDragging = true
                    }
                    onDragMoved?.invoke(dx, dy, event.rawX, event.rawY)
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val totalDx = abs(event.rawX - initialTouchX)
                    val totalDy = abs(event.rawY - initialTouchY)
                    if (!isDragging && totalDx < dp(10) && totalDy < dp(10)) {
                        onPillClicked?.invoke()
                    } else {
                        onDragReleased?.invoke()
                    }
                    true
                }
                else -> false
            }
        }
    }
}
