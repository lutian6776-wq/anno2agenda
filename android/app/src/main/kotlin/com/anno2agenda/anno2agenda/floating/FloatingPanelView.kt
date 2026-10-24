package com.anno2agenda.anno2agenda.floating

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 悬浮窗展开交互面板视图 (Floating Panel View)
 *
 * 纯 UI 组件：负责采集功能按钮栏、原文输入微调框、解析状态指示、
 * 日程实体卡片列表与日历写入按钮，通过 Listener 通知上层逻辑，
 * 不直接依赖 Flutter Channel、OCR 或 CalendarContract。
 */
class FloatingPanelView(context: Context) : LinearLayout(context) {

    var onCloseClicked: (() -> Unit)? = null
    var onReadScreenClicked: (() -> Unit)? = null
    var onScreenshotOcrClicked: (() -> Unit)? = null
    var onReadClipboardClicked: (() -> Unit)? = null
    var onWarmupModelClicked: (() -> Unit)? = null
    var onReAnalyzeClicked: ((String) -> Unit)? = null
    var onWriteAllClicked: ((List<FloatingOverlayEvent>) -> Unit)? = null
    var onOpenPermissionSettingsClicked: (() -> Unit)? = null

    private val inputEditText: EditText
    private val statusTextView: TextView
    private val eventsListLayout: LinearLayout
    private val writeAllButton: Button
    private val modelWarmupBtn: TextView
    private val permissionPromptLayout: LinearLayout
    private val btnReadScreen: TextView
    private val btnScreenshotOcr: TextView
    private val btnReadClip: TextView
    private val reAnalyzeBtn: TextView

    private var currentEvents: List<FloatingOverlayEvent> = emptyList()

    init {
        orientation = VERTICAL
        val screenWidth = resources.displayMetrics.widthPixels
        val panelWidth = (screenWidth * 0.92).toInt().coerceAtMost(dp(400))

        layoutParams = FrameLayout.LayoutParams(
            panelWidth,
            WindowManager.LayoutParams.WRAP_CONTENT
        )
        setPadding(dp(14), dp(12), dp(14), dp(14))
        elevation = dp(16).toFloat()
        background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(20).toFloat()
            setColor(Color.parseColor("#F8FAFC"))
            setStroke(dp(1), Color.parseColor("#CBD5E1"))
        }

        // 1. 顶部标题栏 + 收起按钮
        val headerRow = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val titleView = TextView(context).apply {
            text = "✨ 知程灵动采集（零跳转原地解析）"
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.parseColor("#0F172A"))
            layoutParams = LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
        }
        val closeBtn = TextView(context).apply {
            text = "收起 ✕"
            textSize = 12f
            setTextColor(Color.parseColor("#475569"))
            setPadding(dp(10), dp(4), dp(6), dp(4))
            setOnClickListener { onCloseClicked?.invoke() }
        }
        headerRow.addView(titleView)
        headerRow.addView(closeBtn)
        addView(headerRow)

        // 2. 采集源快捷按钮栏
        val actionScroll = HorizontalScrollView(context).apply {
            isHorizontalScrollBarEnabled = false
            setPadding(0, dp(8), 0, dp(8))
        }
        val actionRow = LinearLayout(context).apply {
            orientation = HORIZONTAL
        }

        btnReadScreen = createChipButton("👁️ 读当前屏幕", "#DBEAFE", "#1D4ED8") {
            onReadScreenClicked?.invoke()
        }
        btnScreenshotOcr = createChipButton("🖼️ 截屏 OCR", "#E0E7FF", "#4338CA") {
            onScreenshotOcrClicked?.invoke()
        }
        btnReadClip = createChipButton("📋 读剪贴板", "#DCFCE7", "#15803D") {
            onReadClipboardClicked?.invoke()
        }
        val btnWarmupModel = createChipButton("⚡ 预热模型", "#FEF3C7", "#92400E") {
            onWarmupModelClicked?.invoke()
        }
        modelWarmupBtn = btnWarmupModel

        actionRow.addView(btnReadScreen)
        actionRow.addView(createSpace(dp(6)))
        actionRow.addView(btnScreenshotOcr)
        actionRow.addView(createSpace(dp(6)))
        actionRow.addView(btnReadClip)
        actionRow.addView(createSpace(dp(6)))
        actionRow.addView(btnWarmupModel)
        actionScroll.addView(actionRow)
        addView(actionScroll)

        // 3. 原文输入与手动重新解析栏
        val inputRow = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        inputEditText = EditText(context).apply {
            hint = "点「读当前屏幕」抓取微信通知，也可直接粘贴修改..."
            textSize = 12.5f
            setTextColor(Color.parseColor("#1E293B"))
            setHintTextColor(Color.parseColor("#94A3B8"))
            maxLines = 3
            setPadding(dp(10), dp(8), dp(10), dp(8))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(10).toFloat()
                setColor(Color.WHITE)
                setStroke(dp(1), Color.parseColor("#E2E8F0"))
            }
            layoutParams = LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
        }
        reAnalyzeBtn = createChipButton("AI 解析", "#2563EB", "#FFFFFF") {
            val text = inputEditText.text?.toString()?.trim() ?: ""
            if (text.isNotEmpty()) {
                onReAnalyzeClicked?.invoke(text)
            }
        }
        inputRow.addView(inputEditText)
        inputRow.addView(createSpace(dp(6)))
        inputRow.addView(reAnalyzeBtn)
        addView(inputRow)

        // 4. 状态提示文本
        statusTextView = TextView(context).apply {
            text = "⚡ 就绪：点「读当前屏幕」免复制抓取通知"
            textSize = 11f
            setTextColor(Color.parseColor("#64748B"))
            setPadding(0, dp(6), 0, dp(6))
        }
        addView(statusTextView)

        // 4.1 权限引导提示横幅（权限缺失时展现）
        permissionPromptLayout = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            visibility = GONE
            setPadding(dp(10), dp(8), dp(10), dp(8))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(10).toFloat()
                setColor(Color.parseColor("#FEF2F2"))
                setStroke(dp(1), Color.parseColor("#FECACA"))
            }
            val permText = TextView(context).apply {
                text = "⚠️ 未获日历权限，点击打开应用授权"
                textSize = 11.5f
                setTextColor(Color.parseColor("#B91C1C"))
                typeface = Typeface.DEFAULT_BOLD
                layoutParams = LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
            }
            val openBtn = TextView(context).apply {
                text = "去授权 →"
                textSize = 11.5f
                setTextColor(Color.parseColor("#2563EB"))
                setPadding(dp(8), dp(2), dp(4), dp(2))
                setOnClickListener { onOpenPermissionSettingsClicked?.invoke() }
            }
            addView(permText)
            addView(openBtn)
        }
        addView(permissionPromptLayout)

        // 5. 解析出的日程卡片滚动容器
        val listScroll = ScrollView(context).apply {
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
        }
        eventsListLayout = LinearLayout(context).apply {
            orientation = VERTICAL
        }
        listScroll.addView(eventsListLayout)
        addView(listScroll)

        // 6. 底部一键静默写入按钮
        writeAllButton = Button(context).apply {
            text = "📅 一键静默写入系统日历"
            textSize = 13f
            setTextColor(Color.WHITE)
            isAllCaps = false
            visibility = GONE
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(12).toFloat()
                setColor(Color.parseColor("#16A34A"))
            }
            setOnClickListener {
                if (currentEvents.isNotEmpty()) {
                    onWriteAllClicked?.invoke(currentEvents)
                }
            }
        }
        val writeParams = LayoutParams(LayoutParams.MATCH_PARENT, dp(42)).apply {
            topMargin = dp(8)
        }
        writeAllButton.layoutParams = writeParams
        addView(writeAllButton)
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun createSpace(widthPx: Int): View {
        return View(context).apply {
            layoutParams = LayoutParams(widthPx, 1)
        }
    }

    private fun createChipButton(
        label: String,
        bgColorHex: String,
        textColorHex: String,
        onClick: () -> Unit
    ): TextView {
        return TextView(context).apply {
            text = label
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.parseColor(textColorHex))
            setPadding(dp(12), dp(7), dp(12), dp(7))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(16).toFloat()
                setColor(Color.parseColor(bgColorHex))
            }
            setOnClickListener { onClick() }
        }
    }

    // ================= 公开状态更新方法 =================

    fun setStatusText(text: String) {
        statusTextView.text = text
    }

    fun setInputText(text: String) {
        inputEditText.setText(text)
        inputEditText.setSelection(text.length)
    }

    fun getInputText(): String {
        return inputEditText.text?.toString()?.trim() ?: ""
    }

    /**
     * 更新正在提取中的 UI 锁定状态，避免重复触发并发推理导致 JNI 状态冲突
     */
    fun setExtracting(isExtracting: Boolean) {
        if (isExtracting) {
            reAnalyzeBtn.isEnabled = false
            reAnalyzeBtn.text = "⏳ 解析中..."
            reAnalyzeBtn.alpha = 0.6f
            btnReadScreen.isEnabled = false
            btnScreenshotOcr.isEnabled = false
            btnReadClip.isEnabled = false
        } else {
            reAnalyzeBtn.isEnabled = true
            reAnalyzeBtn.text = "AI 解析"
            reAnalyzeBtn.alpha = 1.0f
            btnReadScreen.isEnabled = true
            btnScreenshotOcr.isEnabled = true
            btnReadClip.isEnabled = true
        }
    }

    fun setWarmupState(isLoaded: Boolean, isLoading: Boolean, message: String? = null) {
        if (isLoading) {
            modelWarmupBtn.text = "⏳ 预热中..."
            modelWarmupBtn.setTextColor(Color.parseColor("#B45309"))
            (modelWarmupBtn.background as? GradientDrawable)?.setColor(Color.parseColor("#FEF3C7"))
            if (message != null) statusTextView.text = message
        } else if (isLoaded) {
            modelWarmupBtn.text = "🟢 模型已就绪"
            modelWarmupBtn.setTextColor(Color.parseColor("#15803D"))
            (modelWarmupBtn.background as? GradientDrawable)?.setColor(Color.parseColor("#DCFCE7"))
            if (message != null) statusTextView.text = message
        } else {
            modelWarmupBtn.text = "⚡ 预热模型"
            modelWarmupBtn.setTextColor(Color.parseColor("#92400E"))
            (modelWarmupBtn.background as? GradientDrawable)?.setColor(Color.parseColor("#FEF3C7"))
            if (message != null) statusTextView.text = message
        }
    }

    fun setExtractedEvents(events: List<FloatingOverlayEvent>, engineInfo: String) {
        currentEvents = events
        eventsListLayout.removeAllViews()

        val fmt = SimpleDateFormat("MM月dd日 HH:mm", Locale.CHINA)

        for (ev in events.take(3)) {
            val title = ev.title.ifBlank { "校园日程事项" }
            val location = ev.location.ifBlank { "未指定地点" }
            val timeStr = fmt.format(Date(ev.startMillis))

            val itemCard = LinearLayout(context).apply {
                orientation = VERTICAL
                setPadding(dp(10), dp(8), dp(10), dp(8))
                background = GradientDrawable().apply {
                    shape = GradientDrawable.RECTANGLE
                    cornerRadius = dp(10).toFloat()
                    setColor(Color.WHITE)
                    setStroke(dp(1), Color.parseColor("#CBD5E1"))
                }
                layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                    bottomMargin = dp(6)
                }
            }

            val titleTv = TextView(context).apply {
                text = "📌 $title"
                textSize = 13f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(Color.parseColor("#0F172A"))
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }
            val subTv = TextView(context).apply {
                text = "🕒 $timeStr   📍 $location"
                textSize = 11.5f
                setTextColor(Color.parseColor("#475569"))
            }

            itemCard.addView(titleTv)
            itemCard.addView(subTv)

            if (ev.checklist.isNotEmpty()) {
                val clTv = TextView(context).apply {
                    text = "📋 待办：${ev.checklist.joinToString("、")}"
                    textSize = 10.5f
                    setTextColor(Color.parseColor("#2563EB"))
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                }
                itemCard.addView(clTv)
            }

            eventsListLayout.addView(itemCard)
        }

        if (events.isNotEmpty()) {
            writeAllButton.text = "📅 一键静默写入系统日历 (${events.size}项)"
            writeAllButton.visibility = VISIBLE
            writeAllButton.isEnabled = true
            statusTextView.text = "⚡ $engineInfo · 识别出 ${events.size} 个日程事项"
        } else {
            writeAllButton.visibility = GONE
        }
    }

    fun setWritingState(isWriting: Boolean) {
        if (isWriting) {
            writeAllButton.text = "⏳ 正在静默写入系统日历..."
            writeAllButton.isEnabled = false
        } else {
            writeAllButton.text = "📅 一键静默写入系统日历 (${currentEvents.size}项)"
            writeAllButton.isEnabled = true
        }
    }

    fun showPermissionPrompt(show: Boolean) {
        permissionPromptLayout.visibility = if (show) VISIBLE else GONE
    }
}
