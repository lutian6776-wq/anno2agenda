package com.anno2agenda.anno2agenda.floating

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * 封装 Android 悬浮窗与 Flutter AI 推理引擎 (llama.cpp / Ollama / 规则引擎) 之间的通信网关
 *
 * 具备以下能力：
 * 1. 独立管理 MethodChannel 通信链路，不再直接依赖 MainActivity 的静态方法；
 * 2. 完善的 Flutter Engine 未就绪探测、异常捕获与超时熔断保护；
 * 3. 毫秒级原生中文时空正则兜底提取引擎；
 * 4. 支持将悬浮窗写入结果反向同步至 Flutter 内存中的 AgendaRepository。
 */
object FloatingAiGateway {
    @Volatile
    private var activeChannel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * 接收来自主程序端侧大模型推理过程的实时状态/Token流回调
     */
    var onProgressUpdate: ((String) -> Unit)? = null

    fun registerChannel(channel: MethodChannel?) {
        activeChannel = channel
    }

    fun unregisterChannel(channel: MethodChannel?) {
        if (activeChannel == channel) {
            activeChannel = null
        }
    }

    val isEngineReady: Boolean
        get() = activeChannel != null

    /**
     * 发起日程实体抽取请求
     *
     * 优先通过 MethodChannel 请求 Flutter 后台 AI 引擎（支持冷启动加载权重 + 完整推理），
     * 若引擎未就绪、调用出错或超时，自动无缝切换到内置的高校中文通知原生规则引擎。
     */
    fun extractAgenda(
        rawText: String,
        sourceType: String,
        timeoutMs: Long = 180000L,
        onResult: (List<FloatingOverlayEvent>, String) -> Unit
    ) {
        val channel = activeChannel
        if (channel == null) {
            val fallback = fallbackNativeExtract(rawText, sourceType)
            mainHandler.post {
                onResult(fallback, "原生内置规则引擎 (Flutter后台待命中)")
            }
            return
        }

        var isDelivered = false
        val timeoutRunnable = Runnable {
            if (!isDelivered) {
                isDelivered = true
                val fallback = fallbackNativeExtract(rawText, sourceType)
                onResult(fallback, "原生规则兜底 (AI推理超时)")
            }
        }
        mainHandler.postDelayed(timeoutRunnable, timeoutMs)

        mainHandler.post {
            try {
                channel.invokeMethod(
                    "extractAgendaForOverlay",
                    mapOf("text" to rawText, "sourceType" to sourceType),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            mainHandler.removeCallbacks(timeoutRunnable)
                            if (isDelivered) return
                            isDelivered = true

                            val resMap = result as? Map<*, *>
                            val engineUsed = resMap?.get("engineUsed")?.toString() ?: "端侧 AI 引擎"
                            val rawEvents = resMap?.get("events") as? List<*>

                            val parsedList = mutableListOf<FloatingOverlayEvent>()
                            rawEvents?.forEach { item ->
                                val m = item as? Map<*, *> ?: return@forEach
                                parsedList.add(FloatingOverlayEvent.fromMap(m))
                            }

                            if (parsedList.isEmpty()) {
                                val fallback = fallbackNativeExtract(rawText, sourceType)
                                onResult(fallback, "$engineUsed · 原生规则兜底")
                            } else {
                                onResult(parsedList, engineUsed)
                            }
                        }

                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                            mainHandler.removeCallbacks(timeoutRunnable)
                            if (isDelivered) return
                            isDelivered = true
                            val fallback = fallbackNativeExtract(rawText, sourceType)
                            onResult(fallback, "原生规则兜底 ($errorCode)")
                        }

                        override fun notImplemented() {
                            mainHandler.removeCallbacks(timeoutRunnable)
                            if (isDelivered) return
                            isDelivered = true
                            val fallback = fallbackNativeExtract(rawText, sourceType)
                            onResult(fallback, "原生规则兜底 (未实现通道)")
                        }
                    }
                )
            } catch (e: Exception) {
                mainHandler.removeCallbacks(timeoutRunnable)
                if (!isDelivered) {
                    isDelivered = true
                    val fallback = fallbackNativeExtract(rawText, sourceType)
                    onResult(fallback, "原生规则兜底 (${e.message ?: "通信异常"})")
                }
            }
        }
    }

    /**
     * 预热端侧大模型权重
     */
    fun preloadModel(onResult: (Boolean, String) -> Unit) {
        val channel = activeChannel
        if (channel == null) {
            onResult(false, "知程后台服务待命中")
            return
        }
        mainHandler.post {
            try {
                channel.invokeMethod("preloadModelForOverlay", null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val map = result as? Map<*, *>
                        val ok = map?.get("success") == true
                        val msg = map?.get("message")?.toString() ?: if (ok) "模型已预热就绪" else "预热失败"
                        onResult(ok, msg)
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        onResult(false, errorMessage ?: "预热错误 ($errorCode)")
                    }

                    override fun notImplemented() {
                        onResult(false, "通道未实现")
                    }
                })
            } catch (e: Exception) {
                onResult(false, e.message ?: "调用异常")
            }
        }
    }

    /**
     * 检查端侧大模型加载常驻状态
     */
    fun checkModelStatus(onResult: (isLoaded: Boolean, isLoading: Boolean, modelName: String) -> Unit) {
        val channel = activeChannel
        if (channel == null) {
            onResult(false, false, "")
            return
        }
        mainHandler.post {
            try {
                channel.invokeMethod("isModelReadyForOverlay", null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val map = result as? Map<*, *>
                        val isLoaded = map?.get("isLoaded") == true
                        val isLoading = map?.get("isLoading") == true
                        val modelName = map?.get("modelName")?.toString() ?: ""
                        onResult(isLoaded, isLoading, modelName)
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        onResult(false, false, "")
                    }

                    override fun notImplemented() {
                        onResult(false, false, "")
                    }
                })
            } catch (e: Exception) {
                onResult(false, false, "")
            }
        }
    }

    /**
     * 将悬浮窗已成功写入系统日历的日程集合，通过 MethodChannel 反向同步到 Flutter 内存中的 AgendaRepository
     */
    fun syncWrittenEvents(
        events: List<FloatingOverlayEvent>,
        onResult: ((Boolean) -> Unit)? = null
    ) {
        val channel = activeChannel ?: run {
            onResult?.invoke(false)
            return
        }
        mainHandler.post {
            try {
                val payload = events.map { it.toMap() }
                channel.invokeMethod("onOverlayAgendaWritten", payload, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val map = result as? Map<*, *>
                        val ok = map?.get("success") == true
                        onResult?.invoke(ok)
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        onResult?.invoke(false)
                    }

                    override fun notImplemented() {
                        onResult?.invoke(false)
                    }
                })
            } catch (e: Exception) {
                onResult?.invoke(false)
            }
        }
    }

    /**
     * 通知 Flutter 悬浮窗的开启或关闭运行状态
     */
    fun notifyFloatingWindowState(isRunning: Boolean) {
        val channel = activeChannel ?: return
        mainHandler.post {
            try {
                channel.invokeMethod("onFloatingWindowStateChanged", isRunning)
            } catch (_: Exception) {}
        }
    }

    /**
     * 原生轻量启发式规则引擎（当主程序后台处于深度休眠或离线时兜底运作）
     */
    fun fallbackNativeExtract(rawText: String, sourceType: String): List<FloatingOverlayEvent> {
        val cal = Calendar.getInstance()
        if (rawText.contains("后天")) {
            cal.add(Calendar.DAY_OF_YEAR, 2)
        } else if (rawText.contains("明天") || rawText.contains("明日")) {
            cal.add(Calendar.DAY_OF_YEAR, 1)
        } else if (rawText.contains("今天") || rawText.contains("今日")) {
            // keep current day
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
        cal.set(Calendar.MILLISECOND, 0)

        val locMatch =
            Regex("""(?:在|地点[:：]?\s*|腾讯会议[:：号\s]*)([^\s，,。；;\n]{2,20})""").find(rawText)
        val location = locMatch?.groupValues?.getOrNull(1) ?: ""
        val cleanTitle = rawText.replace("\n", " ").trim().take(22)
        val startMillis = cal.timeInMillis
        val endMillis = startMillis + 3600_000L

        val isoFmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.CHINA)
        val eventId = (System.currentTimeMillis() * 1000L).toString()

        return listOf(
            FloatingOverlayEvent(
                id = eventId,
                title = cleanTitle.ifBlank { "提取自通知的事项" },
                startTime = isoFmt.format(Date(startMillis)),
                startMillis = startMillis,
                endTime = isoFmt.format(Date(endMillis)),
                endMillis = endMillis,
                location = location,
                description = rawText,
                sourceText = rawText,
                sourceType = sourceType,
                reminderMinutes = 30,
                checklist = emptyList(),
                confidence = 0.88,
                syncedToSystemCalendar = false,
                deviceOrigin = "android"
            )
        )
    }
}
