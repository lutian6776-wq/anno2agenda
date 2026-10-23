package com.anno2agenda.anno2agenda

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.os.Build
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions

class ScreenCaptureAccessibilityService : AccessibilityService() {

    companion object {
        var instance: ScreenCaptureAccessibilityService? = null
            private set

        val isServiceEnabled: Boolean
            get() = instance != null

        private val ignoredUiWords = setOf(
            "返回", "发送", "更多", "语音", "表情", "拍摄", "相册", "视频通话",
            "文件", "转账", "红包", "位置", "收藏", "名片", "微信", "通讯录",
            "发现", "我", "消息", "联系人", "动态", "按住 说话"
        )
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 仅在用户主动点击悬浮窗「读屏提取」或「截屏OCR」时按需读取，平时 0 性能消耗、不后台窃取隐私
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }

    /**
     * 方案 A：免截屏、免 OCR，毫秒级直接读取当前屏幕应用（如微信/QQ/浏览器）控件树上的文本气泡
     */
    fun extractCurrentScreenText(): String {
        val collected = LinkedHashSet<String>()

        // 优先遍历所有活动窗口，跳过本应用悬浮窗与系统状态栏
        val winList = try {
            windows
        } catch (_: Exception) {
            null
        }

        if (!winList.isNullOrEmpty()) {
            for (win in winList) {
                val root = win.root ?: continue
                val pkg = root.packageName?.toString() ?: ""
                if (pkg == packageName || pkg == "com.android.systemui") {
                    continue
                }
                traverseNode(root, collected)
            }
        }

        // 若多窗口列表为空，回退读取 rootInActiveWindow
        if (collected.isEmpty()) {
            val activeRoot = try {
                rootInActiveWindow
            } catch (_: Exception) {
                null
            }
            if (activeRoot != null && activeRoot.packageName?.toString() != packageName) {
                traverseNode(activeRoot, collected)
            }
        }

        // 优先筛选出像通知/消息的文本段落（长度 >= 6 或包含数字/时间词）
        val meaningful = collected.filter { line ->
            line.length >= 6 || Regex("""(\d+[月日点时:：]|明天|后天|周[一二三四五六日天]|会议|地点|教室|楼|截止)""").containsMatchIn(line)
        }

        return if (meaningful.isNotEmpty()) {
            meaningful.joinToString("\n")
        } else {
            collected.joinToString("\n")
        }
    }

    private fun traverseNode(node: AccessibilityNodeInfo?, out: MutableSet<String>) {
        if (node == null) return
        if (!node.isVisibleToUser) return

        val text = node.text?.toString()?.trim()
        val desc = node.contentDescription?.toString()?.trim()

        if (!text.isNullOrEmpty() && text.length >= 2 && text !in ignoredUiWords) {
            out.add(text)
        } else if (!desc.isNullOrEmpty() && desc.length >= 6 && desc !in ignoredUiWords) {
            out.add(desc)
        }

        val count = node.childCount
        for (i in 0 until count) {
            val child = try {
                node.getChild(i)
            } catch (_: Exception) {
                null
            }
            if (child != null) {
                traverseNode(child, out)
            }
        }
    }

    /**
     * 方案 B：遇到图片海报/课表截图时，调用 Android 11+ (API 30) 原生静默截屏 + 内置中文离线 OCR
     */
    fun takeSilentScreenshotAndOcr(onResult: (Boolean, String) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            onResult(false, "静默截屏需 Android 11 及以上系统")
            return
        }

        try {
            takeScreenshot(
                Display.DEFAULT_DISPLAY,
                mainExecutor,
                object : TakeScreenshotCallback {
                    override fun onSuccess(screenshotResult: ScreenshotResult) {
                        try {
                            val hwBuffer = screenshotResult.hardwareBuffer
                            val colorSpace = screenshotResult.colorSpace
                            val hwBitmap = Bitmap.wrapHardwareBuffer(hwBuffer, colorSpace)
                            val softBitmap = hwBitmap?.copy(Bitmap.Config.ARGB_8888, false)
                            hwBuffer.close()
                            hwBitmap?.recycle()

                            if (softBitmap == null) {
                                onResult(false, "截屏图像转换失败")
                                return
                            }

                            val recognizer = TextRecognition.getClient(
                                ChineseTextRecognizerOptions.Builder().build()
                            )
                            val inputImage = InputImage.fromBitmap(softBitmap, 0)
                            recognizer.process(inputImage)
                                .addOnSuccessListener { visionText ->
                                    softBitmap.recycle()
                                    val recognized = visionText.text.trim()
                                    if (recognized.isEmpty()) {
                                        onResult(false, "截屏中未识别到文字内容")
                                    } else {
                                        onResult(true, recognized)
                                    }
                                }
                                .addOnFailureListener { e ->
                                    softBitmap.recycle()
                                    onResult(false, "端侧 OCR 识别异常: ${e.message}")
                                }
                        } catch (e: Exception) {
                            onResult(false, "处理截屏失败: ${e.message}")
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        onResult(false, "静默截屏失败 (错误码 $errorCode，请稍后重试)")
                    }
                }
            )
        } catch (e: Exception) {
            onResult(false, "调用截屏异常: ${e.message}")
        }
    }
}
