package com.anno2agenda.anno2agenda.floating

import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.anno2agenda.anno2agenda.ScreenCaptureAccessibilityService

/**
 * 统一管理悬浮窗四大无感文本采集源 (Floating Capture Coordinator)
 *
 * 1. Accessibility 读当前屏幕控件树文字；
 * 2. Android 11+ 原生静默截屏 + 离线中文 OCR 识别；
 * 3. 读取系统剪贴板；
 * 4. 用户手动输入或编辑校正。
 */
class FloatingCaptureCoordinator(private val context: Context) {
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * 采集源 1：通过无障碍服务直接读取当前屏幕应用文字
     */
    fun captureCurrentScreen(onResult: (FloatingCaptureResult) -> Unit) {
        val a11y = ScreenCaptureAccessibilityService.instance
        if (a11y == null) {
            onResult(
                FloatingCaptureResult(
                    text = "",
                    sourceType = "screen_a11y",
                    success = false,
                    errorMessage = "未开启无障碍服务，请在系统设置中启用「知程 AI 识屏与静默截屏助手」"
                )
            )
            return
        }

        val text = a11y.extractCurrentScreenText().trim()
        if (text.isEmpty()) {
            onResult(
                FloatingCaptureResult(
                    text = "",
                    sourceType = "screen_a11y",
                    success = false,
                    errorMessage = "当前屏幕未探测到文字内容，若是海报或图片通知请点击「🖼️ 截屏 OCR」"
                )
            )
            return
        }

        onResult(
            FloatingCaptureResult(
                text = text,
                sourceType = "screen_a11y",
                success = true
            )
        )
    }

    /**
     * 采集源 2：静默截屏并运行端侧中文 OCR
     *
     * @param onBeforeScreenshot 截屏前钩子（用于临时隐藏悬浮窗本身，避免自身遮挡底层文字）
     * @param onAfterScreenshot 截屏完成钩子（恢复悬浮窗显示）
     */
    fun captureScreenshotOcr(
        onBeforeScreenshot: () -> Unit,
        onAfterScreenshot: () -> Unit,
        onResult: (FloatingCaptureResult) -> Unit
    ) {
        val a11y = ScreenCaptureAccessibilityService.instance
        if (a11y == null) {
            onResult(
                FloatingCaptureResult(
                    text = "",
                    sourceType = "screenshot_ocr",
                    success = false,
                    errorMessage = "未开启无障碍服务，请在系统设置中启用「知程 AI 识屏与静默截屏助手」"
                )
            )
            return
        }

        onBeforeScreenshot()

        mainHandler.postDelayed({
            a11y.takeSilentScreenshotAndOcr { ok, recognizedText ->
                mainHandler.post {
                    onAfterScreenshot()
                    if (ok && recognizedText.isNotBlank()) {
                        onResult(
                            FloatingCaptureResult(
                                text = recognizedText.trim(),
                                sourceType = "screenshot_ocr",
                                success = true
                            )
                        )
                    } else {
                        onResult(
                            FloatingCaptureResult(
                                text = "",
                                sourceType = "screenshot_ocr",
                                success = false,
                                errorMessage = recognizedText.ifBlank { "截屏中未识别出有效文字" }
                            )
                        )
                    }
                }
            }
        }, 140)
    }

    /**
     * 采集源 3：读取系统剪贴板内容
     */
    fun captureClipboard(
        silentIfEmpty: Boolean = false,
        onResult: (FloatingCaptureResult) -> Unit
    ) {
        mainHandler.postDelayed({
            var clipText = ""
            try {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                val item = cm?.primaryClip?.getItemAt(0)
                clipText = item?.coerceToText(context)?.toString()?.trim() ?: ""
            } catch (_: Exception) {}

            if (clipText.isNotBlank()) {
                onResult(
                    FloatingCaptureResult(
                        text = clipText,
                        sourceType = "floating_clipboard",
                        success = true
                    )
                )
            } else {
                onResult(
                    FloatingCaptureResult(
                        text = "",
                        sourceType = "floating_clipboard",
                        success = false,
                        errorMessage = if (silentIfEmpty) null else "剪贴板为空，请先复制通知文本或点击「👁️ 读当前屏幕」"
                    )
                )
            }
        }, 80)
    }

    /**
     * 采集源 4：包装手动输入或二次编辑的原文字符串
     */
    fun wrapManualText(text: String): FloatingCaptureResult {
        val clean = text.trim()
        return FloatingCaptureResult(
            text = clean,
            sourceType = "floating_edit",
            success = clean.isNotEmpty(),
            errorMessage = if (clean.isEmpty()) "请输入或粘贴通知原文" else null
        )
    }
}
