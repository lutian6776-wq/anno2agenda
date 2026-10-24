package com.anno2agenda.anno2agenda.floating

import android.app.Service
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.widget.Toast

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
        const val EXTRA_FLOATING_TEXT = "extra_floating_text"
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

        val bView = FloatingBubbleView(this)
        val pView = FloatingPanelView(this)
        val controller = FloatingWindowController(this, bView, pView)
        val coordinator = FloatingCaptureCoordinator(this)

        bubbleView = bView
        panelView = pView
        windowController = controller
        captureCoordinator = coordinator

        setupBubbleInteractions(bView, pView, controller, coordinator)
        setupPanelInteractions(pView, controller, coordinator)

        FloatingAiGateway.notifyFloatingWindowState(true)
    }

    private fun setupBubbleInteractions(
        bubble: FloatingBubbleView,
        panel: FloatingPanelView,
        controller: FloatingWindowController,
        coordinator: FloatingCaptureCoordinator
    ) {
        bubble.onPillClicked = {
            controller.expandPanel()
            // 展开面板后，异步检查端侧大模型是否常驻，并同步状态至界面
            FloatingAiGateway.checkModelStatus { isLoaded, isLoading, _ ->
                mainHandler.post {
                    panel.setWarmupState(isLoaded, isLoading)
                }
            }

            // 优先自动执行无感识别：屏幕文字 -> 剪贴板文字
            if (!isExtracting) {
                coordinator.captureCurrentScreen { res ->
                    if (res.success && res.text.isNotBlank()) {
                        panel.setInputText(res.text)
                        triggerAiExtraction(panel, res.text, res.sourceType)
                    } else {
                        coordinator.captureClipboard(silentIfEmpty = true) { clipRes ->
                            if (clipRes.success && clipRes.text.isNotBlank()) {
                                panel.setInputText(clipRes.text)
                                triggerAiExtraction(panel, clipRes.text, clipRes.sourceType)
                            }
                        }
                    }
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
            controller.collapseToPill()
        }

        panel.onReadScreenClicked = {
            if (isExtracting) {
                panel.setStatusText("⏳ 正在提取日程，请稍候...")
            } else {
                panel.setStatusText("👁️ 正在通过无障碍控件树直接读取屏幕通知...")
                coordinator.captureCurrentScreen { res ->
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
            }
        }

        panel.onScreenshotOcrClicked = {
            if (isExtracting) {
                panel.setStatusText("⏳ 正在提取日程，请稍候...")
            } else {
                panel.setStatusText("📸 正在静默截屏并运行端侧离线中文 OCR...")
                coordinator.captureScreenshotOcr(
                    onBeforeScreenshot = {
                        controller.hideTemporarilyForScreenshot(140) {}
                    },
                    onAfterScreenshot = {},
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
                coordinator.captureClipboard(silentIfEmpty = false) { res ->
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
        panel.setStatusText("🧠 正在调用端侧 AI 引擎提取结构化日程...")

        FloatingAiGateway.extractAgenda(rawText, sourceType) { events, engineInfo ->
            mainHandler.post {
                isExtracting = false
                panel.setExtracting(false)
                panel.setExtractedEvents(events, engineInfo)
            }
        }
    }

    override fun onDestroy() {
        isRunning = false
        isExtracting = false
        FloatingAiGateway.notifyFloatingWindowState(false)
        windowController?.destroy()
        windowController = null
        bubbleView = null
        panelView = null
        captureCoordinator = null
        super.onDestroy()
    }
}
