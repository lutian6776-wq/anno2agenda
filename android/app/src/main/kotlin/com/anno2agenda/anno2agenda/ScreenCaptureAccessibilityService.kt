package com.anno2agenda.anno2agenda

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.graphics.Bitmap
import android.os.Build
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions

class ScreenCaptureAccessibilityService : AccessibilityService() {

    companion object {
        var instance: ScreenCaptureAccessibilityService? = null
            private set

        val isServiceEnabled: Boolean
            get() = instance != null
    }

    @Volatile
    private var lastCachedAppTexts: List<String> = emptyList()
    @Volatile
    private var lastCacheTimestamp: Long = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        // 在保留 XML 声明的 canRetrieveWindowContent 与 canTakeScreenshot 能力前提下，补充增强视图标志
        try {
            val info = serviceInfo
            if (info != null) {
                info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
                info.feedbackType =
                    AccessibilityServiceInfo.FEEDBACK_SPOKEN or AccessibilityServiceInfo.FEEDBACK_GENERIC
                info.flags = info.flags or
                        AccessibilityServiceInfo.DEFAULT or
                        AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                        AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                        AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
                serviceInfo = info
            }
        } catch (_: Exception) {}
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        // 当悬浮窗开启时，在后台轻量记录当前宿主应用主窗口的最新节点快照（节流 800ms），
        // 防止部分定制 ROM 在点击悬浮窗瞬间临时切换焦点导致活动窗口短暂为空
        if (!com.anno2agenda.anno2agenda.floating.FloatingBubbleService.isRunning) return

        val pkg = event.packageName?.toString() ?: ""
        if (pkg.isEmpty() || isIgnoredWindowPackage(pkg)) return

        val now = System.currentTimeMillis()
        if (now - lastCacheTimestamp < 800L) return

        val root = try {
            rootInActiveWindow ?: event.source
        } catch (_: Exception) {
            null
        } ?: return

        val rootPkg = root.packageName?.toString() ?: pkg
        if (isIgnoredWindowPackage(rootPkg)) return

        lastCacheTimestamp = now
        val snapshot = LinkedHashSet<String>()
        traverseNode(root, snapshot, 0)
        if (snapshot.isNotEmpty()) {
            lastCachedAppTexts = snapshot.toList()
        }
    }

    private fun isIgnoredWindowPackage(pkg: String): Boolean {
        return pkg == packageName ||
                pkg == "com.android.systemui" ||
                pkg.contains("inputmethod") ||
                pkg.contains("latinime") ||
                pkg.contains("sohu.inputmethod") ||
                pkg.contains("baidu.input") ||
                pkg.contains("iflytek.inputmethod")
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }

    /**
     * 方案 A：免截屏、免 OCR，直接深度遍历当前屏幕主应用（如微信/QQ/飞书/钉钉/浏览器）完整无障碍节点树
     * 严格排除 com.android.systemui 顶部状态栏（时间/电量/信号/通知图标）与软键盘干扰，
     * 对主应用窗口内容不做任何关键词黑名单、长度截断或正则过滤，保留完整原始上下文交由端侧 LLM 理解。
     */
    fun extractCurrentScreenText(): String {
        val collected = LinkedHashSet<String>()

        // 1. 先读取所有应用层窗口 (TYPE_APPLICATION)，彻底跳过 com.android.systemui 状态栏与本应用悬浮窗
        val winList = try {
            windows
        } catch (_: Exception) {
            null
        }

        if (!winList.isNullOrEmpty()) {
            val appWindows = winList.filter { win ->
                win.type == AccessibilityWindowInfo.TYPE_APPLICATION ||
                        win.type == AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER
            }
            val targetWindows = if (appWindows.isNotEmpty()) appWindows else winList

            for (win in targetWindows) {
                if (win.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue
                val root = try {
                    win.root
                } catch (_: Exception) {
                    null
                } ?: continue
                val pkg = root.packageName?.toString() ?: ""
                if (isIgnoredWindowPackage(pkg)) {
                    continue
                }
                traverseNode(root, collected, 0)
            }
        }

        // 2. 同时检查 rootInActiveWindow（补充可能未出现在 windows 列表中的当前焦点主窗口）
        val activeRoot = try {
            rootInActiveWindow
        } catch (_: Exception) {
            null
        }
        if (activeRoot != null) {
            val activePkg = activeRoot.packageName?.toString() ?: ""
            if (!isIgnoredWindowPackage(activePkg)) {
                traverseNode(activeRoot, collected, 0)
            }
        }

        // 3. 若因悬浮窗焦点切换瞬态导致实时查询为空，回退使用点击悬浮窗前已捕获的宿主应用主窗口快照
        if (collected.isEmpty() && lastCachedAppTexts.isNotEmpty()) {
            collected.addAll(lastCachedAppTexts)
        }

        return collected.joinToString("\n")
    }

    /**
     * 深度优先遍历全部子节点（对齐 TalkBack 读屏行为）：
     * - 不因父容器 isVisibleToUser == false 而剪枝（IM 聊天列表容器/自绘 View 常返回 false，但其子节点包含聊天文本）
     * - 同时收集 text、contentDescription 与 hintText，不使用 else-if 互斥丢弃，也不做字数/词表过滤
     */
    private fun traverseNode(
        node: AccessibilityNodeInfo?,
        out: MutableSet<String>,
        depth: Int
    ) {
        if (node == null || depth > 80) return

        val text = try {
            node.text?.toString()?.trim()
        } catch (_: Exception) {
            null
        }
        val desc = try {
            node.contentDescription?.toString()?.trim()
        } catch (_: Exception) {
            null
        }
        val hint = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                node.hintText?.toString()?.trim()
            } catch (_: Exception) {
                null
            }
        } else {
            null
        }

        if (!text.isNullOrEmpty()) {
            out.add(text)
        }
        if (!desc.isNullOrEmpty() && desc != text) {
            out.add(desc)
        }
        if (!hint.isNullOrEmpty() && hint != text && hint != desc) {
            out.add(hint)
        }

        val count = try {
            node.childCount
        } catch (_: Exception) {
            0
        }
        for (i in 0 until count) {
            val child = try {
                node.getChild(i)
            } catch (_: Exception) {
                null
            }
            if (child != null) {
                traverseNode(child, out, depth + 1)
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
