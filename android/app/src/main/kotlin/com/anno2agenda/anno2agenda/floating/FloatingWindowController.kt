package com.anno2agenda.anno2agenda.floating

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import kotlin.math.max
import kotlin.math.min

/**
 * 悬浮窗 WindowManager 窗口控制器 (Floating Window Controller)
 *
 * 专门负责管理系统全局窗口、图层参数、折叠/展开状态切换、拖拽坐标更新、松手自动贴边吸附与截图隐身。
 */
class FloatingWindowController(
    private val context: Context,
    private val bubbleView: FloatingBubbleView,
    private val panelView: FloatingPanelView
) {
    private val windowManager: WindowManager =
        context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val rootContainer: FrameLayout = FrameLayout(context)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var layoutParams: WindowManager.LayoutParams? = null
    var isExpanded: Boolean = false
        private set

    private var initialX = 0
    private var initialY = 0

    private val idleDimRunnable = Runnable {
        if (!isExpanded) {
            bubbleView.setDimmed(true)
        }
    }

    init {
        panelView.visibility = View.GONE
        rootContainer.addView(bubbleView)
        rootContainer.addView(panelView)

        val overlayType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = dp(140)
        }

        layoutParams = params
        try {
            windowManager.addView(rootContainer, params)
        } catch (_: Exception) {}

        scheduleIdleDim()
    }

    private fun dp(value: Int): Int {
        return (value * context.resources.displayMetrics.density).toInt()
    }

    fun scheduleIdleDim() {
        mainHandler.removeCallbacks(idleDimRunnable)
        bubbleView.setDimmed(false)
        mainHandler.postDelayed(idleDimRunnable, 3200)
    }

    fun onDragStarted() {
        mainHandler.removeCallbacks(idleDimRunnable)
        layoutParams?.let {
            initialX = it.x
            initialY = it.y
        }
    }

    fun onDragMoved(dx: Int, dy: Int) {
        val params = layoutParams ?: return
        val screenWidth = context.resources.displayMetrics.widthPixels
        val screenHeight = context.resources.displayMetrics.heightPixels

        params.x = max(0, min(screenWidth - bubbleView.width, initialX + dx))
        params.y = max(dp(40), min(screenHeight - dp(100), initialY + dy))
        try {
            windowManager.updateViewLayout(rootContainer, params)
        } catch (_: Exception) {}
    }

    fun onDragReleased() {
        snapToNearestEdge()
        scheduleIdleDim()
    }

    /**
     * 松手自动吸附贴合最近屏幕边缘（左侧或右侧）
     */
    fun snapToNearestEdge() {
        val params = layoutParams ?: return
        val screenWidth = context.resources.displayMetrics.widthPixels
        val pillWidth = bubbleView.width.takeIf { it > 0 } ?: dp(72)

        params.x = if (params.x + pillWidth / 2 < screenWidth / 2) {
            0
        } else {
            screenWidth - pillWidth
        }
        try {
            windowManager.updateViewLayout(rootContainer, params)
        } catch (_: Exception) {}
    }

    /**
     * 展开悬浮卡片并允许获取输入焦点
     */
    fun expandPanel() {
        val params = layoutParams ?: return
        isExpanded = true
        mainHandler.removeCallbacks(idleDimRunnable)

        bubbleView.visibility = View.GONE
        panelView.visibility = View.VISIBLE

        // 移除 FLAG_NOT_FOCUSABLE 允许读取剪贴板及在 EditText 中输入微调
        params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
        params.x = (context.resources.displayMetrics.widthPixels * 0.04).toInt()
        params.y = dp(90)

        try {
            windowManager.updateViewLayout(rootContainer, params)
        } catch (_: Exception) {}
    }

    /**
     * 收起为折叠态贴边小胶囊
     */
    fun collapseToPill() {
        val params = layoutParams ?: return
        isExpanded = false
        panelView.visibility = View.GONE
        bubbleView.visibility = View.VISIBLE

        // 恢复 FLAG_NOT_FOCUSABLE 避免拦截下方宿主应用手势
        params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        snapToNearestEdge()
        scheduleIdleDim()
    }

    /**
     * 截屏前临时将整个容器隐身 140ms，避免遮挡底层应用内容
     */
    fun hideTemporarilyForScreenshot(durationMs: Long = 140L, onHidden: () -> Unit) {
        rootContainer.visibility = View.INVISIBLE
        mainHandler.postDelayed({
            onHidden()
            rootContainer.visibility = View.VISIBLE
        }, durationMs)
    }

    /**
     * 安全移除悬浮窗，杜绝 WindowLeaked 崩溃
     */
    fun destroy() {
        mainHandler.removeCallbacks(idleDimRunnable)
        try {
            windowManager.removeView(rootContainer)
        } catch (_: Exception) {}
    }
}
