package com.anno2agenda.anno2agenda.floating

import android.content.Context
import android.util.Log
import com.anno2agenda.anno2agenda.CalendarWriterHelper
import org.json.JSONArray
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.nio.charset.StandardCharsets

/**
 * 悬浮窗系统日历写入网关 (Floating Calendar Gateway)
 *
 * 负责：
 * 1. 检查 Android 日历读写权限；
 * 2. 将统一日程模型转换为 Android CalendarContract 参数并执行静默写入；
 * 3. 严格去重：避免同一事件重复写入系统日历；
 * 4. 离线持久化：即使 Flutter 进程当前未存活，直接写入沙盒 agenda_events.json；
 * 5. 内存同步：若 Flutter 引擎处于活动状态，通知其即时刷新工作台与我的日程；
 * 6. 返回逐条详细结果 FloatingBatchWriteResult。
 */
object FloatingCalendarGateway {
    private const val TAG = "FloatingCalendarGateway"
    private const val STORAGE_FILE_NAME = "agenda_events.json"

    fun hasCalendarPermission(context: Context): Boolean {
        return CalendarWriterHelper.hasCalendarPermission(context)
    }

    /**
     * 批量将悬浮窗日程写入系统日历并持久化至本地
     */
    fun writeEvents(
        context: Context,
        events: List<FloatingOverlayEvent>
    ): FloatingBatchWriteResult {
        if (!hasCalendarPermission(context)) {
            Log.w(TAG, "缺少日历读写权限，终止写入")
            val deniedResults = events.map { ev ->
                FloatingWriteResult(
                    eventId = ev.id,
                    success = false,
                    message = "未授予系统日历读写权限，请在知程主界面或系统设置中允许日历权限",
                    persisted = false,
                    permissionDenied = true
                )
            }
            return FloatingBatchWriteResult(deniedResults)
        }

        val writeResults = mutableListOf<FloatingWriteResult>()
        val succeededEvents = mutableListOf<FloatingOverlayEvent>()

        for (event in events) {
            try {
                // 1. 去重校验：检查日历中是否已存在
                val existingCalId = CalendarWriterHelper.findExistingCalendarEventId(
                    context,
                    event.title,
                    event.startMillis
                )

                if (existingCalId != null) {
                    event.syncedToSystemCalendar = true
                    event.systemCalendarEventId = existingCalId.toString()
                    succeededEvents.add(event)
                    writeResults.add(
                        FloatingWriteResult(
                            eventId = event.id,
                            success = true,
                            message = "日历中已存在该日程（ID: $existingCalId），已自动跳过重复写入",
                            persisted = true,
                            systemCalendarEventId = existingCalId.toString()
                        )
                    )
                    continue
                }

                // 2. 写入系统日历
                val insertRes = CalendarWriterHelper.insertIntoSystemCalendar(context, event.toMap())
                val ok = insertRes["success"] == true
                val msg = insertRes["message"]?.toString() ?: if (ok) "已静默写入系统日历" else "写入日历失败"
                val calEventId = insertRes["eventId"]?.toString()
                    ?: insertRes["systemCalendarEventId"]?.toString()

                if (ok) {
                    event.syncedToSystemCalendar = true
                    event.systemCalendarEventId = calEventId
                    succeededEvents.add(event)
                    writeResults.add(
                        FloatingWriteResult(
                            eventId = event.id,
                            success = true,
                            message = msg,
                            persisted = true,
                            systemCalendarEventId = calEventId
                        )
                    )
                } else {
                    writeResults.add(
                        FloatingWriteResult(
                            eventId = event.id,
                            success = false,
                            message = msg,
                            persisted = false
                        )
                    )
                }
            } catch (e: Exception) {
                Log.e(TAG, "写入单条日程异常: ${event.title}", e)
                writeResults.add(
                    FloatingWriteResult(
                        eventId = event.id,
                        success = false,
                        message = "写入异常: ${e.message}",
                        persisted = false
                    )
                )
            }
        }

        // 3. 离线持久化写入沙盒存储（确保 Flutter 未打开时数据亦绝对持久化）
        if (succeededEvents.isNotEmpty()) {
            try {
                persistEventsToDisk(context, succeededEvents)
            } catch (e: Exception) {
                Log.e(TAG, "本地沙盒持久化异常", e)
            }

            // 4. 若 Flutter 引擎存活，通过通道即时同步内存仓库
            FloatingAiGateway.syncWrittenEvents(succeededEvents)
        }

        return FloatingBatchWriteResult(writeResults)
    }

    /**
     * 将日程合并持久化到与 Flutter 共享的沙盒 agenda_events.json 中
     */
    @Synchronized
    private fun persistEventsToDisk(context: Context, newEvents: List<FloatingOverlayEvent>) {
        val file = File(context.filesDir, STORAGE_FILE_NAME)
        val existingEvents = mutableListOf<FloatingOverlayEvent>()

        if (file.exists()) {
            try {
                val jsonStr = file.readText(StandardCharsets.UTF_8).trim()
                if (jsonStr.isNotEmpty()) {
                    val array = JSONArray(jsonStr)
                    for (i in 0 until array.length()) {
                        val obj = array.getJSONObject(i)
                        existingEvents.add(FloatingOverlayEvent.fromJsonObject(obj))
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "解析现有本地持久化日程失败，将建立新记录: ${e.message}")
            }
        }

        // 去重合并
        for (newItem in newEvents) {
            val idx = existingEvents.indexOfFirst {
                it.id == newItem.id || (
                    it.title.trim() == newItem.title.trim() &&
                    it.location.trim() == newItem.location.trim() &&
                    kotlin.math.abs(it.startMillis - newItem.startMillis) <= 60_000L
                )
            }
            if (idx >= 0) {
                existingEvents[idx] = newItem
            } else {
                existingEvents.add(newItem)
            }
        }

        // 写入 JSON 数组
        val outArray = JSONArray()
        for (item in existingEvents) {
            outArray.put(item.toJsonObject())
        }

        val tempFile = File(context.filesDir, "$STORAGE_FILE_NAME.tmp")
        OutputStreamWriter(FileOutputStream(tempFile), StandardCharsets.UTF_8).use { writer ->
            writer.write(outArray.toString())
            writer.flush()
        }

        if (file.exists()) {
            file.delete()
        }
        tempFile.renameTo(file)
        Log.i(TAG, "成功将 ${existingEvents.size} 项日程持久化到 ${file.absolutePath}")
    }
}
