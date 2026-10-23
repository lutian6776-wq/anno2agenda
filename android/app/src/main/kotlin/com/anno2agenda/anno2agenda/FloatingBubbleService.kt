package com.anno2agenda.anno2agenda

import android.app.Service
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.abs

class FloatingBubbleService : Service() {
    companion object {
        var isRunning: Boolean = false
        const val EXTRA_FLOATING_TEXT = "extra_floating_text"
    }

    private var windowManager: WindowManager? = null
    private var rootContainer: FrameLayout? = null
    private var collapsedPillView: TextView? = null
    private var expandedPanelView: LinearLayout? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    private var inputEditText: EditText? = null
    private var statusTextView: TextView? = null
    private var eventsListLayout: LinearLayout? = null
    private var writeAllButton: Button? = null
    private var modelWarmupBtn: TextView? = null

    private var isExpanded = false
    private var currentExtractedEvents: List<Map<String, Any>> = emptyList()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val idleDimRunnable = Runnable {
        if (!isExpanded) {
            collapsedPillView?.alpha = 0.65f
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager

        val container = FrameLayout(this)
        val pill = buildCollapsedPill()
        val panel = buildExpandedPanel()
        panel.visibility = View.GONE

        container.addView(pill)
        container.addView(panel)

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
            y = 420
        }

        rootContainer = container
        collapsedPillView = pill
        expandedPanelView = panel
        layoutParams = params

        windowManager?.addView(container, params)
        scheduleIdleDim()
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun scheduleIdleDim() {
        mainHandler.removeCallbacks(idleDimRunnable)
        collapsedPillView?.alpha = 0.96f
        mainHandler.postDelayed(idleDimRunnable, 3200)
    }

    /**
     * 构建折叠态贴边灵动小球（支持拖拽、松手自动贴边吸附、闲置半透明）
     */
    private fun buildCollapsedPill(): TextView {
        val pill = TextView(this).apply {
            text = "📅 知程"
            setTextColor(Color.WHITE)
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(14), dp(9), dp(14), dp(9))
            elevation = dp(8).toFloat()
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(24).toFloat()
                setColor(Color.parseColor("#2563EB"))
                setStroke(dp(2), Color.parseColor("#93C5FD"))
            }
        }

        var initialX = 0
        var initialY = 0
        var initialTouchX = 0f
        var initialTouchY = 0f

        pill.setOnTouchListener { _, event ->
            val params = layoutParams ?: return@setOnTouchListener false
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    scheduleIdleDim()
                    initialX = params.x
                    initialY = params.y
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    params.x = initialX + (event.rawX - initialTouchX).toInt()
                    params.y = initialY + (event.rawY - initialTouchY).toInt()
                    rootContainer?.let { windowManager?.updateViewLayout(it, params) }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val dx = abs(event.rawX - initialTouchX)
                    val dy = abs(event.rawY - initialTouchY)
                    if (dx < dp(10) && dy < dp(10)) {
                        expandPanelAndAutoCapture()
                    } else {
                        snapToNearestEdge()
                        scheduleIdleDim()
                    }
                    true
                }
                else -> false
            }
        }
        return pill
    }

    private fun snapToNearestEdge() {
        val params = layoutParams ?: return
        val screenWidth = resources.displayMetrics.widthPixels
        val pillWidth = collapsedPillView?.width ?: dp(72)
        params.x = if (params.x + pillWidth / 2 < screenWidth / 2) {
            0
        } else {
            screenWidth - pillWidth
        }
        rootContainer?.let { windowManager?.updateViewLayout(it, params) }
    }

    /**
     * 构建原地展开的半透明悬浮交互卡片（全程无需跳出微信/QQ）
     */
    private fun buildExpandedPanel(): LinearLayout {
        val screenWidth = resources.displayMetrics.widthPixels
        val panelWidth = (screenWidth * 0.92).toInt().coerceAtMost(dp(400))

        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
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
        }

        // 1. 顶部标题栏 + 收起按钮
        val headerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val titleView = TextView(this).apply {
            text = "✨ 知程灵动采集（零跳转原地解析）"
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.parseColor("#0F172A"))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val closeBtn = TextView(this).apply {
            text = "收起 ✕"
            textSize = 12f
            setTextColor(Color.parseColor("#475569"))
            setPadding(dp(10), dp(4), dp(6), dp(4))
            setOnClickListener { collapseToPill() }
        }
        headerRow.addView(titleView)
        headerRow.addView(closeBtn)
        panel.addView(headerRow)

        // 2. 三大无感采集入口按钮栏：读屏提取 / 截屏OCR / 读剪贴板
        val actionScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            setPadding(0, dp(8), 0, dp(8))
        }
        val actionRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }

        val btnReadScreen = createChipButton("👁️ 读当前屏幕", "#DBEAFE", "#1D4ED8") {
            handleReadScreenText()
        }
        val btnScreenshotOcr = createChipButton("🖼️ 截屏 OCR", "#E0E7FF", "#4338CA") {
            handleSilentScreenshotOcr()
        }
        val btnReadClip = createChipButton("📋 读剪贴板", "#DCFCE7", "#15803D") {
            handleReadClipboard()
        }
        val btnWarmupModel = createChipButton("⚡ 预热模型", "#FEF3C7", "#92400E") {
            handleWarmupModel()
        }
        modelWarmupBtn = btnWarmupModel

        actionRow.addView(btnReadScreen)
        actionRow.addView(SpaceView(this, dp(6)))
        actionRow.addView(btnScreenshotOcr)
        actionRow.addView(SpaceView(this, dp(6)))
        actionRow.addView(btnReadClip)
        actionRow.addView(SpaceView(this, dp(6)))
        actionRow.addView(btnWarmupModel)
        actionScroll.addView(actionRow)
        panel.addView(actionScroll)

        // 3. 可编辑通知原文框 + 重新解析按钮
        val inputRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val edit = EditText(this).apply {
            hint = "点击上方「读当前屏幕」或「截屏OCR」自动抓取通知，也可直接粘贴修改..."
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
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val reAnalyzeBtn = createChipButton("AI 解析", "#2563EB", "#FFFFFF") {
            val txt = inputEditText?.text?.toString()?.trim() ?: ""
            if (txt.isNotEmpty()) {
                triggerAiExtraction(txt, "floating_edit")
            }
        }
        inputEditText = edit
        inputRow.addView(edit)
        inputRow.addView(SpaceView(this, dp(6)))
        inputRow.addView(reAnalyzeBtn)
        panel.addView(inputRow)

        // 4. 状态提示行
        val statusTv = TextView(this).apply {
            text = "⚡ 就绪：点「读当前屏幕」免复制抓取微信/浏览器通知"
            textSize = 11f
            setTextColor(Color.parseColor("#64748B"))
            setPadding(0, dp(6), 0, dp(6))
        }
        statusTextView = statusTv
        panel.addView(statusTv)

        // 5. 提取出的日程结果滚动列表
        val listScroll = ScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }
        val listContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        eventsListLayout = listContainer
        listScroll.addView(listContainer)
        panel.addView(listScroll)

        // 6. 底部一键静默写入系统日历按钮
        val writeBtn = Button(this).apply {
            text = "📅 一键静默写入系统日历"
            textSize = 13f
            setTextColor(Color.WHITE)
            isAllCaps = false
            visibility = View.GONE
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(12).toFloat()
                setColor(Color.parseColor("#16A34A"))
            }
            setOnClickListener {
                writeAllCurrentEventsToCalendar()
            }
        }
        val writeParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(42)
        ).apply {
            topMargin = dp(8)
        }
        writeBtn.layoutParams = writeParams
        writeAllButton = writeBtn
        panel.addView(writeBtn)

        return panel
    }

    private fun createChipButton(
        label: String,
        bgColorHex: String,
        textColorHex: String,
        onClick: () -> Unit
    ): TextView {
        return TextView(this).apply {
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

    private class SpaceView(context: Context, widthPx: Int) : View(context) {
        init {
            layoutParams = LinearLayout.LayoutParams(widthPx, 1)
        }
    }

    /**
     * 点击悬浮小球：原地展开为可交互卡片，并自动优先尝试「无障碍读屏 -> 剪贴板读取」
     */
    private fun expandPanelAndAutoCapture() {
        val params = layoutParams ?: return
        isExpanded = true
        mainHandler.removeCallbacks(idleDimRunnable)

        collapsedPillView?.visibility = View.GONE
        expandedPanelView?.visibility = View.VISIBLE

        // 移除 FLAG_NOT_FOCUSABLE 以允许读取剪贴板及在 EditText 中输入微调
        params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
        params.x = (resources.displayMetrics.widthPixels * 0.04).toInt()
        params.y = dp(90)
        rootContainer?.let { windowManager?.updateViewLayout(it, params) }

        checkAndUpdateModelWarmupButton()

        // 若无障碍服务已开启，优先自动读取当前屏幕文字；否则自动读取剪贴板
        val a11y = ScreenCaptureAccessibilityService.instance
        if (a11y != null) {
            val screenText = a11y.extractCurrentScreenText()
            if (screenText.isNotBlank()) {
                inputEditText?.setText(screenText)
                triggerAiExtraction(screenText, "screen_a11y")
                return
            }
        }
        handleReadClipboard(silentIfEmpty = true)
    }

    private fun handleWarmupModel() {
        val btn = modelWarmupBtn ?: return
        btn.text = "⏳ 预热中..."
        btn.setTextColor(Color.parseColor("#B45309"))
        (btn.background as? GradientDrawable)?.setColor(Color.parseColor("#FEF3C7"))
        statusTextView?.text = "⏳ 正在加载模型权重至内存/GPU..."

        MainActivity.preloadModelForOverlay { ok, msg ->
            mainHandler.post {
                if (ok) {
                    btn.text = "🟢 模型已就绪"
                    btn.setTextColor(Color.parseColor("#15803D"))
                    (btn.background as? GradientDrawable)?.setColor(Color.parseColor("#DCFCE7"))
                    statusTextView?.text = "🟢 模型已预热常驻内存，稍后提取将秒级直出"
                } else {
                    btn.text = "⚡ 预热模型"
                    btn.setTextColor(Color.parseColor("#92400E"))
                    (btn.background as? GradientDrawable)?.setColor(Color.parseColor("#FEF3C7"))
                    statusTextView?.text = "提示: $msg"
                }
            }
        }
    }

    private fun checkAndUpdateModelWarmupButton() {
        MainActivity.checkModelStatusForOverlay { isLoaded, isLoading, _ ->
            mainHandler.post {
                val btn = modelWarmupBtn ?: return@post
                if (isLoading) {
                    btn.text = "⏳ 预热中..."
                    btn.setTextColor(Color.parseColor("#B45309"))
                    (btn.background as? GradientDrawable)?.setColor(Color.parseColor("#FEF3C7"))
                } else if (isLoaded) {
                    btn.text = "🟢 模型已就绪"
                    btn.setTextColor(Color.parseColor("#15803D"))
                    (btn.background as? GradientDrawable)?.setColor(Color.parseColor("#DCFCE7"))
                } else {
                    btn.text = "⚡ 预热模型"
                    btn.setTextColor(Color.parseColor("#92400E"))
                    (btn.background as? GradientDrawable)?.setColor(Color.parseColor("#FEF3C7"))
                }
            }
        }
    }

    private fun collapseToPill() {
        val params = layoutParams ?: return
        isExpanded = false
        expandedPanelView?.visibility = View.GONE
        collapsedPillView?.visibility = View.VISIBLE

        params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        snapToNearestEdge()
        scheduleIdleDim()
    }

    /**
     * 动作 1：无障碍直接读取当前屏幕文字（免复制、免截屏，0.01 秒）
     */
    private fun handleReadScreenText() {
        val a11y = ScreenCaptureAccessibilityService.instance
        if (a11y == null) {
            statusTextView?.text = "⚠️ 请先在弹出的系统设置中开启「知程 AI 识屏与静默截屏助手」无障碍服务"
            Toast.makeText(
                this,
                "请开启「知程 AI 识屏与静默截屏助手」无障碍权限",
                Toast.LENGTH_LONG
            ).show()
            collapseToPill()
            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            return
        }

        val text = a11y.extractCurrentScreenText()
        if (text.isBlank()) {
            statusTextView?.text = "当前屏幕未检测到文字控件，若是图片海报请点「🖼️ 截屏 OCR」"
            return
        }
        inputEditText?.setText(text)
        triggerAiExtraction(text, "screen_a11y")
    }

    /**
     * 动作 2：Android 11+ 静默截屏 + 端侧中文离线 OCR
     */
    private fun handleSilentScreenshotOcr() {
        val a11y = ScreenCaptureAccessibilityService.instance
        if (a11y == null) {
            handleReadScreenText()
            return
        }

        statusTextView?.text = "📸 正在静默截屏并运行端侧中文 OCR..."
        // 截屏前将悬浮窗自身隐藏 120ms，防止悬浮窗遮挡屏幕上的海报文字
        rootContainer?.visibility = View.INVISIBLE

        mainHandler.postDelayed({
            a11y.takeSilentScreenshotAndOcr { ok, resultText ->
                mainHandler.post {
                    rootContainer?.visibility = View.VISIBLE
                    if (ok) {
                        inputEditText?.setText(resultText)
                        triggerAiExtraction(resultText, "screenshot_ocr")
                    } else {
                        statusTextView?.text = "⚠️ $resultText"
                    }
                }
            }
        }, 140)
    }

    /**
     * 动作 3：读取系统剪贴板
     */
    private fun handleReadClipboard(silentIfEmpty: Boolean = false) {
        mainHandler.postDelayed({
            var clipText = ""
            try {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val item = cm.primaryClip?.getItemAt(0)
                clipText = item?.coerceToText(this)?.toString()?.trim() ?: ""
            } catch (_: Exception) {}

            if (clipText.isNotEmpty()) {
                inputEditText?.setText(clipText)
                triggerAiExtraction(clipText, "floating_clipboard")
            } else if (!silentIfEmpty) {
                statusTextView?.text = "⚠️ 剪贴板为空，可点击「👁️ 读当前屏幕」直接抓取屏幕通知"
            }
        }, 100)
    }

    /**
     * 调用后台 Flutter 端侧 AI 引擎（Qwen3.5 / 规则引擎）进行解析，并在悬浮卡片内直接渲染结果
     */
    private fun triggerAiExtraction(rawText: String, sourceType: String) {
        statusTextView?.text = "🧠 正在调用端侧 AI 引擎提取日程节点..."
        eventsListLayout?.removeAllViews()
        writeAllButton?.visibility = View.GONE

        MainActivity.extractAgendaForOverlay(rawText, sourceType) { events, engineInfo ->
            mainHandler.post {
                val finalEvents = events.ifEmpty {
                    fallbackNativeExtract(rawText)
                }
                currentExtractedEvents = finalEvents
                statusTextView?.text = "⚡ $engineInfo · 识别出 ${finalEvents.size} 个日程"
                renderExtractedEvents(finalEvents)
            }
        }
    }

    private fun renderExtractedEvents(events: List<Map<String, Any>>) {
        val container = eventsListLayout ?: return
        container.removeAllViews()

        val fmt = SimpleDateFormat("MM月dd日 HH:mm", Locale.CHINA)

        for (ev in events.take(3)) {
            val title = ev["title"]?.toString() ?: "校园日程事项"
            val location = ev["location"]?.toString()?.ifBlank { "未指定地点" } ?: "未指定地点"
            val startMillis = (ev["startMillis"] as? Number)?.toLong() ?: System.currentTimeMillis()
            val timeStr = fmt.format(Date(startMillis))

            val itemCard = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(10), dp(8), dp(10), dp(8))
                background = GradientDrawable().apply {
                    shape = GradientDrawable.RECTANGLE
                    cornerRadius = dp(10).toFloat()
                    setColor(Color.WHITE)
                    setStroke(dp(1), Color.parseColor("#CBD5E1"))
                }
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    bottomMargin = dp(6)
                }
            }

            val titleTv = TextView(this).apply {
                text = "📌 $title"
                textSize = 13f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(Color.parseColor("#0F172A"))
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }
            val subTv = TextView(this).apply {
                text = "🕒 $timeStr   📍 $location"
                textSize = 11.5f
                setTextColor(Color.parseColor("#475569"))
            }

            itemCard.addView(titleTv)
            itemCard.addView(subTv)
            container.addView(itemCard)
        }

        if (events.isNotEmpty()) {
            writeAllButton?.text = "📅 一键静默写入系统日历 (${events.size}项)"
            writeAllButton?.visibility = View.VISIBLE
        }
    }

    private fun writeAllCurrentEventsToCalendar() {
        if (currentExtractedEvents.isEmpty()) return
        var successCount = 0
        var lastMsg = ""
        for (ev in currentExtractedEvents) {
            val res = CalendarWriterHelper.insertIntoSystemCalendar(this, ev)
            if (res["success"] == true) {
                successCount++
            }
            lastMsg = res["message"]?.toString() ?: ""
        }

        if (successCount > 0) {
            Toast.makeText(
                this,
                "✅ 已静默将 $successCount 项日程写入系统日历并设好提醒！",
                Toast.LENGTH_LONG
            ).show()
            collapseToPill()
        } else {
            Toast.makeText(this, "⚠️ $lastMsg", Toast.LENGTH_LONG).show()
        }
    }

    /**
     * 原生层轻量兜底提取器（当主界面被系统回收时仍可独立完成解析）
     */
    private fun fallbackNativeExtract(rawText: String): List<Map<String, Any>> {
        val cal = Calendar.getInstance()
        if (rawText.contains("后天")) {
            cal.add(Calendar.DAY_OF_YEAR, 2)
        } else if (rawText.contains("明天") || rawText.contains("明日")) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }
        val timeMatch = Regex("""(\d{1,2})[:：点时](\d{1,2}|半)?""").find(rawText)
        var hour = if (rawText.contains("下午") || rawText.contains("晚")) 14 else 9
        var minute = 0
        if (timeMatch != null) {
            hour = timeMatch.groupValues[1].toIntOrNull() ?: hour
            val mStr = timeMatch.groupValues[2]
            minute = if (mStr == "半") 30 else (mStr.toIntOrNull() ?: 0)
            if ((rawText.contains("下午") || rawText.contains("晚")) && hour < 12) {
                hour += 12
            }
        }
        cal.set(Calendar.HOUR_OF_DAY, hour.coerceIn(0, 23))
        cal.set(Calendar.MINUTE, minute.coerceIn(0, 59))
        cal.set(Calendar.SECOND, 0)

        val locMatch =
            Regex("""(?:在|地点[:：]?\s*|腾讯会议[:：号\s]*)([^\s，,。；;\n]{2,20})""").find(rawText)
        val location = locMatch?.groupValues?.getOrNull(1) ?: ""
        val cleanTitle = rawText.replace("\n", " ").take(22)
        val startMillis = cal.timeInMillis

        return listOf(
            mapOf(
                "title" to cleanTitle,
                "location" to location,
                "description" to rawText,
                "startMillis" to startMillis,
                "endMillis" to (startMillis + 3600_000L),
                "reminderMinutes" to 30
            )
        )
    }

    override fun onDestroy() {
        isRunning = false
        mainHandler.removeCallbacks(idleDimRunnable)
        rootContainer?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {}
        }
        rootContainer = null
        super.onDestroy()
    }
}
