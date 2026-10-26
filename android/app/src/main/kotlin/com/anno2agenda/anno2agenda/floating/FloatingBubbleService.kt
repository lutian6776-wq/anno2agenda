package com.anno2agenda.anno2agenda.floating

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.widget.Toast
import androidx.core.app.NotificationCompat

/**
 * Android 原生灵动悬浮窗后台服务 (Floating Bubble Service)
 *
 * 遵循高内聚低耦合职责设计：
 * 仅承担 Service 启动与销毁生命周期编排，将窗口控制、视图渲染、输入采集、AI 网关及日历写入
 * 分别委托给专门的协作组件。
 */
class FloatingBubbleService : Service() {

    companion object {
        var isRunning: Boolean = false
        var instance: FloatingBubbleService? = null
            private set

        const val EXTRA_FLOATING_TEXT = "extra_floating_text"
        private const val PREFS_NAME = "anno2agenda_prefs"
        private const val KEY_THEME_MODE = "theme_mode"
        private const val NOTIF_CHANNEL_ID = "anno2agenda_floating_channel"
        private const val NOTIF_ID = 10086

        fun updateThemeMode(context: Context, mode: String) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_THEME_MODE, mode)
                .apply()
            instance?.refreshTheme()
        }
    }

    private var windowController: FloatingWindowController? = null
    private var bubbleView: FloatingBubbleView? = null
    private var panelView: FloatingPanelView? = null
    private var captureCoordinator: FloatingCaptureCoordinator? = null

    @Volatile
    private var isExtracting: Boolean = false

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        instance = this
        startForegroundSafely()

        val bView = FloatingBubbleView(this)
        val pView = FloatingPanelView(this)
        val controller = FloatingWindowController(this, bView, pView)
        val coordinator = FloatingCaptureCoordinator(this)

        bubbleView = bView
        panelView = pView
        windowController = controller
        captureCoordinator = coordinator

        refreshTheme()
        setupBubbleInteractions(bView, pView, controller)
        setupPanelInteractions(pView, controller, coordinator)

        FloatingAiGateway.onProgressUpdate = { statusMsg ->
            mainHandler.post {
                if (isExtracting) {
                    panelView?.setStatusText(statusMsg)
                }
            }
        }

        FloatingAiGateway.notifyFloatingWindowState(true)
    }

    private fun startForegroundSafely() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                val channel = NotificationChannel(
                    NOTIF_CHANNEL_ID,
                    "知程灵动悬浮窗服务",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "保持端侧 AI 模型与灵动识屏悬浮窗后台活跃"
                    setShowBadge(false)
                }
                nm?.createNotificationChannel(channel)
            }
            val notif = NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
                .setContentTitle("知程灵动悬浮窗运行中")
                .setContentText("支持跨应用原地识屏与端侧 AI 提取日程")
                .setSmallIcon(android.R.drawable.ic_menu_my_calendar)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .build()
            startForeground(NOTIF_ID, notif)
        } catch (_: Exception) {}
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        refreshTheme(newConfig)
    }

    fun refreshTheme(configOverride: Configuration? = null) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val mode = prefs.getString(KEY_THEME_MODE, "system") ?: "system"
        val cfg = configOverride ?: resources.configuration
        val isDark = when (mode) {
            "dark" -> true
            "light" -> false
            else -> (cfg.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }
        mainHandler.post {
            bubbleView?.applyTheme(isDark)
            panelView?.applyTheme(isDark)
        }
    }

    private fun setupBubbleInteractions(
        bubble: FloatingBubbleView,
        panel: FloatingPanelView,
        controller: FloatingWindowController
    ) {
        bubble.onPillClicked = {
            refreshTheme()
            controller.expandPanel()
            // 仅展开面板并同步端侧大模型状态，不再自动读取或粘贴剪贴板/屏幕文字
            FloatingAiGateway.checkModelStatus { isLoaded, isLoading, _ ->
                mainHandler.post {
                    panel.setWarmupState(isLoaded, isLoading)
                }
            }
        }

        bubble.onDragStarted = {
            controller.onDragStarted()
        }

        bubble.onDragMoved = { dx, dy, _, _ ->
            controller.onDragMoved(dx, dy)
        }

        bubble.onDragReleased = {
            controller.onDragReleased()
        }
    }

    private fun setupPanelInteractions(
        panel: FloatingPanelView,
        controller: FloatingWindowController,
        coordinator: FloatingCaptureCoordinator
    ) {
        panel.onCloseClicked = {
            controller.setKeyboardFocusable(false)
            controller.collapseToPill()
        }

        panel.onInputFocusRequested = {
            controller.setKeyboardFocusable(true)
        }

        panel.onReadScreenClicked = {
            if (isExtracting) {
                panel.setStatusText("⏳ 正在提取日程，请稍候...")
            } else {
                controller.setKeyboardFocusable(false)
                panel.setStatusText("👁️ 正在通过无障碍节点树深度读取当前屏幕主窗口...")
                coordinator.captureCurrentScreen(
                    onBeforeCapture = {
                        // 彻底隐藏悬浮窗并归还焦点给底层微信/QQ主窗口
                        controller.setOverlayHiddenForCapture(true)
                    },
                    onAfterCapture = {
                        controller.setOverlayHiddenForCapture(false)
                    },
                    onResult = { res ->
                        if (res.success) {
                            panel.setInputText(res.text)
                            triggerAiExtraction(panel, res.text, res.sourceType)
                        } else {
                            panel.setStatusText("⚠️ ${res.errorMessage ?: "读取屏幕失败"}")
                            if (res.errorMessage?.contains("无障碍") == true) {
                                Toast.makeText(
                                    this,
                                    "请先在系统设置中启用「知程 AI 识屏与静默截屏助手」",
                                    Toast.LENGTH_LONG
                                ).show()
                                controller.collapseToPill()
                                try {
                                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    startActivity(intent)
                                } catch (_: Exception) {}
                            }
                        }
                    }
                )
            }
        }

        panel.onScreenshotOcrClicked = {
            if (isExtracting) {
                panel.setStatusText("⏳ 正在提取日程，请稍候...")
            } else {
                controller.setKeyboardFocusable(false)
                panel.setStatusText("📸 正在静默截屏并运行端侧离线中文 OCR...")
                coordinator.captureScreenshotOcr(
                    onBeforeScreenshot = {
                        controller.setOverlayHiddenForCapture(true)
                    },
                    onAfterScreenshot = {
                        controller.setOverlayHiddenForCapture(false)
                    },
                    onResult = { res ->
                        if (res.success) {
                            panel.setInputText(res.text)
                            triggerAiExtraction(panel, res.text, res.sourceType)
                        } else {
                            panel.setStatusText("⚠️ ${res.errorMessage ?: "截屏 OCR 未识别出文字"}")
                        }
                    }
                )
            }
        }

        panel.onReadClipboardClicked = {
            if (isExtracting) {
                panel.setStatusText("⏳ 正在提取日程，请稍候...")
            } else {
                panel.setStatusText("📋 正在读取系统剪贴板...")
                // Android 10+ 读取剪贴板需要窗口临时具备焦点
                controller.setKeyboardFocusable(true)
                coordinator.captureClipboard(silentIfEmpty = false) { res ->
                    controller.setKeyboardFocusable(false)
                    if (res.success) {
                        panel.setInputText(res.text)
                        triggerAiExtraction(panel, res.text, res.sourceType)
                    } else {
                        panel.setStatusText("⚠️ ${res.errorMessage ?: "剪贴板为空"}")
                    }
                }
            }
        }

        panel.onWarmupModelClicked = {
            panel.setWarmupState(isLoaded = false, isLoading = true, message = "⏳ 正在加载模型权重至系统内存/GPU...")
            FloatingAiGateway.preloadModel { ok, msg ->
                mainHandler.post {
                    if (ok) {
                        panel.setWarmupState(isLoaded = true, isLoading = false, message = "🟢 模型已预热常驻内存，稍后提取秒级直出")
                    } else {
                        panel.setWarmupState(isLoaded = false, isLoading = false, message = "提示: $msg")
                    }
                }
            }
        }

        panel.onReAnalyzeClicked = { text ->
            if (isExtracting) {
                panel.setStatusText("⏳ 正在提取日程，请勿重复点击...")
            } else {
                val wrapped = coordinator.wrapManualText(text)
                if (wrapped.success) {
                    triggerAiExtraction(panel, wrapped.text, wrapped.sourceType)
                } else {
                    panel.setStatusText("⚠️ ${wrapped.errorMessage}")
                }
            }
        }

        panel.onWriteAllClicked = { events ->
            panel.setWritingState(true)
            panel.setStatusText("📅 正在将 ${events.size} 项日程静默写入系统日历并持久化...")

            // 异步执行日历写入与沙盒落盘
            Thread {
                val batchRes = FloatingCalendarGateway.writeEvents(this, events)
                mainHandler.post {
                    panel.setWritingState(false)
                    if (batchRes.hasPermissionDenied) {
                        panel.setStatusText("⚠️ 未获得日历权限，请点击下方前往授权")
                        panel.showPermissionPrompt(true)
                        Toast.makeText(this, "未授予系统日历读写权限，无法写入日历", Toast.LENGTH_LONG).show()
                    } else {
                        panel.showPermissionPrompt(false)
                        Toast.makeText(this, batchRes.summaryMessage(), Toast.LENGTH_LONG).show()
                        if (batchRes.successCount > 0) {
                            controller.collapseToPill()
                        } else {
                            panel.setStatusText("⚠️ 全部写入失败，请检查日程参数或日志")
                        }
                    }
                }
            }.start()
        }

        panel.onOpenPermissionSettingsClicked = {
            try {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
            } catch (_: Exception) {
                try {
                    val intent = Intent(Settings.ACTION_SETTINGS).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                } catch (_: Exception) {}
            }
        }
    }

    private fun triggerAiExtraction(
        panel: FloatingPanelView,
        rawText: String,
        sourceType: String
    ) {
        if (isExtracting) {
            panel.setStatusText("⏳ 正在解析中，请稍候...")
            return
        }
        isExtracting = true
        panel.setExtracting(true)
        panel.setStatusText("🧠 正在唤起主程序端侧大模型提取结构化日程...")

        var wakeLock: PowerManager.WakeLock? = null
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
            wakeLock = pm?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Anno2Agenda:FloatingAiWakeLock"
            )?.apply {
                acquire(180_000L)
            }
        } catch (_: Exception) {}

        FloatingAiGateway.extractAgenda(rawText, sourceType) { events, engineInfo ->
            try {
                if (wakeLock?.isHeld == true) {
                    wakeLock.release()
                }
            } catch (_: Exception) {}

            mainHandler.post {
                isExtracting = false
                panel.setExtracting(false)
                panel.setExtractedEvents(events, engineInfo)
                // 提取完成后刷新模型常驻状态徽章
                FloatingAiGateway.checkModelStatus { isLoaded, isLoading, _ ->
                    mainHandler.post {
                        panel.setWarmupState(isLoaded, isLoading)
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        isRunning = false
        isExtracting = false
        if (instance === this) {
            instance = null
        }
        FloatingAiGateway.onProgressUpdate = null
        FloatingAiGateway.notifyFloatingWindowState(false)
        windowController?.destroy()
        windowController = null
        bubbleView = null
        panelView = null
        captureCoordinator = null
        super.onDestroy()
    }
}
