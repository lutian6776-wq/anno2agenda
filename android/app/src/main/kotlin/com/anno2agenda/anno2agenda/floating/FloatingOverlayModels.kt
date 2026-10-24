package com.anno2agenda.anno2agenda.floating

import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 悬浮窗与应用内部通用的统一日程数据模型 (Floating Overlay Event DTO)
 *
 * 严格对齐 Flutter 端 AgendaEvent 契约规范，包含完整属性字段，保证跨进程与 MethodChannel 传输无损。
 */
data class FloatingOverlayEvent(
    val id: String,
    var title: String,
    var startTime: String,
    var startMillis: Long,
    var endTime: String,
    var endMillis: Long,
    var location: String = "",
    var description: String = "",
    val sourceText: String = "",
    val sourceType: String = "floating",
    var reminderMinutes: Int = 30,
    var checklist: List<String> = emptyList(),
    val confidence: Double = 0.9,
    var syncedToSystemCalendar: Boolean = false,
    var systemCalendarEventId: String? = null,
    val deviceOrigin: String = "android"
) {
    fun toMap(): Map<String, Any> {
        val map = mutableMapOf<String, Any>(
            "id" to id,
            "title" to title,
            "startTime" to startTime,
            "startMillis" to startMillis,
            "endTime" to endTime,
            "endMillis" to endMillis,
            "location" to location,
            "description" to description,
            "sourceText" to sourceText,
            "sourceType" to sourceType,
            "reminderMinutes" to reminderMinutes,
            "checklist" to checklist,
            "confidence" to confidence,
            "syncedToSystemCalendar" to syncedToSystemCalendar,
            "deviceOrigin" to deviceOrigin
        )
        systemCalendarEventId?.let {
            if (it.isNotBlank()) map["systemCalendarEventId"] = it
        }
        return map
    }

    fun toJsonObject(): JSONObject {
        return JSONObject().apply {
            put("id", id)
            put("title", title)
            put("startTime", startTime)
            put("startMillis", startMillis)
            put("endTime", endTime)
            put("endMillis", endMillis)
            put("location", location)
            put("description", description)
            put("sourceText", sourceText)
            put("sourceType", sourceType)
            put("reminderMinutes", reminderMinutes)
            put("checklist", JSONArray(checklist))
            put("confidence", confidence)
            put("syncedToSystemCalendar", syncedToSystemCalendar)
            systemCalendarEventId?.let {
                if (it.isNotBlank()) put("systemCalendarEventId", it)
            }
            put("deviceOrigin", deviceOrigin)
        }
    }

    companion object {
        private val isoFmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.CHINA)

        fun fromMap(map: Map<*, *>): FloatingOverlayEvent {
            val startMs = (map["startMillis"] as? Number)?.toLong()
                ?: System.currentTimeMillis()
            val endMs = (map["endMillis"] as? Number)?.toLong()
                ?: (startMs + 3600_000L)

            val startTimeStr = map["startTime"]?.toString()?.ifBlank { null }
                ?: isoFmt.format(Date(startMs))
            val endTimeStr = map["endTime"]?.toString()?.ifBlank { null }
                ?: isoFmt.format(Date(endMs))

            val idStr = map["id"]?.toString()?.ifBlank { null }
                ?: (System.currentTimeMillis() * 1000L).toString()

            val checklistList = mutableListOf<String>()
            (map["checklist"] as? List<*>)?.forEach { item ->
                if (item != null) checklistList.add(item.toString())
            }

            return FloatingOverlayEvent(
                id = idStr,
                title = map["title"]?.toString() ?: "未命名日程",
                startTime = startTimeStr,
                startMillis = startMs,
                endTime = endTimeStr,
                endMillis = endMs,
                location = map["location"]?.toString() ?: "",
                description = map["description"]?.toString() ?: "",
                sourceText = map["sourceText"]?.toString() ?: "",
                sourceType = map["sourceType"]?.toString() ?: "floating",
                reminderMinutes = (map["reminderMinutes"] as? Number)?.toInt() ?: 30,
                checklist = checklistList,
                confidence = (map["confidence"] as? Number)?.toDouble() ?: 0.9,
                syncedToSystemCalendar = map["syncedToSystemCalendar"] == true,
                systemCalendarEventId = map["systemCalendarEventId"]?.toString(),
                deviceOrigin = map["deviceOrigin"]?.toString() ?: "android"
            )
        }

        fun fromJsonObject(obj: JSONObject): FloatingOverlayEvent {
            val id = obj.optString("id", (System.currentTimeMillis() * 1000L).toString())
            val title = obj.optString("title", "未命名日程")
            val startMs = obj.optLong("startMillis", System.currentTimeMillis())
            val endMs = obj.optLong("endMillis", startMs + 3600_000L)
            val startTime = obj.optString("startTime", isoFmt.format(Date(startMs)))
            val endTime = obj.optString("endTime", isoFmt.format(Date(endMs)))
            val location = obj.optString("location", "")
            val description = obj.optString("description", "")
            val sourceText = obj.optString("sourceText", "")
            val sourceType = obj.optString("sourceType", "floating")
            val reminderMinutes = obj.optInt("reminderMinutes", 30)
            val confidence = obj.optDouble("confidence", 0.9)
            val synced = obj.optBoolean("syncedToSystemCalendar", false)
            val calEventId = if (obj.has("systemCalendarEventId") && !obj.isNull("systemCalendarEventId")) {
                obj.optString("systemCalendarEventId")
            } else null
            val deviceOrigin = obj.optString("deviceOrigin", "android")

            val checklistList = mutableListOf<String>()
            val clArray = obj.optJSONArray("checklist")
            if (clArray != null) {
                for (i in 0 until clArray.length()) {
                    checklistList.add(clArray.optString(i))
                }
            }

            return FloatingOverlayEvent(
                id = id,
                title = title,
                startTime = startTime,
                startMillis = startMs,
                endTime = endTime,
                endMillis = endMs,
                location = location,
                description = description,
                sourceText = sourceText,
                sourceType = sourceType,
                reminderMinutes = reminderMinutes,
                checklist = checklistList,
                confidence = confidence,
                syncedToSystemCalendar = synced,
                systemCalendarEventId = calEventId,
                deviceOrigin = deviceOrigin
            )
        }
    }
}

/**
 * 文本采集统一载荷
 */
data class FloatingCaptureResult(
    val text: String,
    val sourceType: String, // 'screen_a11y', 'screenshot_ocr', 'floating_clipboard', 'floating_edit'
    val success: Boolean,
    val errorMessage: String? = null
)

/**
 * 单条事件写入底层日历结果
 */
data class FloatingWriteResult(
    val eventId: String,
    val success: Boolean,
    val message: String,
    val persisted: Boolean,
    val systemCalendarEventId: String? = null,
    val permissionDenied: Boolean = false
) {
    fun toMap(): Map<String, Any> {
        val map = mutableMapOf<String, Any>(
            "eventId" to eventId,
            "success" to success,
            "message" to message,
            "persisted" to persisted,
            "permissionDenied" to permissionDenied
        )
        systemCalendarEventId?.let { map["systemCalendarEventId"] = it }
        return map
    }
}

/**
 * 批量日程写入统计汇总
 */
data class FloatingBatchWriteResult(
    val results: List<FloatingWriteResult>
) {
    val totalCount: Int get() = results.size
    val successCount: Int get() = results.count { it.success }
    val failureCount: Int get() = results.count { !it.success }
    val isAllSuccess: Boolean get() = failureCount == 0 && totalCount > 0
    val hasPermissionDenied: Boolean get() = results.any { it.permissionDenied }

    fun summaryMessage(): String {
        if (totalCount == 0) return "没有待写入的日程事项"
        if (hasPermissionDenied) {
            return "未授予系统日历读写权限，无法写入系统日历"
        }
        if (isAllSuccess) {
            return "✅ 已静默将 $totalCount 项日程写入系统日历并完成同步！"
        }
        return "写入完成：成功 $successCount 项，失败 $failureCount 项"
    }
}
