package com.anno2agenda.anno2agenda

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import java.util.TimeZone

object CalendarWriterHelper {

    fun hasCalendarPermission(context: Context): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.READ_CALENDAR
        ) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.WRITE_CALENDAR
                ) == PackageManager.PERMISSION_GRANTED
    }

    fun insertIntoSystemCalendar(context: Context, args: Map<*, *>): Map<String, Any> {
        if (!hasCalendarPermission(context)) {
            return mapOf(
                "success" to false,
                "message" to "尚未授予日历权限，请先在知程主界面或系统设置中允许日历访问权限",
                "permissionDenied" to true
            )
        }

        return try {
            val calId = getOrCreateWritableCalendarId(context)
                ?: return mapOf("success" to false, "message" to "未找到可写入的系统日历账户")

            val title = args["title"]?.toString() ?: "知程事项"
            val description = args["description"]?.toString() ?: ""
            val location = args["location"]?.toString() ?: ""
            val startMillis =
                (args["startMillis"] as? Number)?.toLong() ?: System.currentTimeMillis()
            val endMillis =
                (args["endMillis"] as? Number)?.toLong() ?: (startMillis + 3600_000L)
            val reminderMinutes = (args["reminderMinutes"] as? Number)?.toInt() ?: 30

            // 写入前检查是否已存在相同标题与开始时间的日程，实现底层日历去重
            val existingEventId = findExistingCalendarEventId(context, title, startMillis)
            if (existingEventId != null) {
                return mapOf(
                    "success" to true,
                    "message" to "日历中已存在相同日程（事件ID: $existingEventId），已自动跳过重复写入",
                    "eventId" to existingEventId.toString(),
                    "systemCalendarEventId" to existingEventId.toString(),
                    "alreadyExists" to true
                )
            }

            val values = ContentValues().apply {
                put(CalendarContract.Events.DTSTART, startMillis)
                put(CalendarContract.Events.DTEND, endMillis)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION, description)
                put(CalendarContract.Events.EVENT_LOCATION, location)
                put(CalendarContract.Events.CALENDAR_ID, calId)
                put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
                put(CalendarContract.Events.HAS_ALARM, 1)
            }

            val eventUri =
                context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
            val eventId = eventUri?.lastPathSegment?.toLongOrNull()

            if (eventId != null && reminderMinutes >= 0) {
                val reminderValues = ContentValues().apply {
                    put(CalendarContract.Reminders.EVENT_ID, eventId)
                    put(CalendarContract.Reminders.MINUTES, reminderMinutes)
                    put(
                        CalendarContract.Reminders.METHOD,
                        CalendarContract.Reminders.METHOD_ALERT
                    )
                }
                context.contentResolver.insert(
                    CalendarContract.Reminders.CONTENT_URI,
                    reminderValues
                )
            }

            val resMap = mutableMapOf<String, Any>(
                "success" to true,
                "message" to "已静默写入系统日历（事件ID: ${eventId ?: "OK"}，提前 ${reminderMinutes} 分钟提醒）"
            )
            if (eventId != null) {
                resMap["eventId"] = eventId.toString()
                resMap["systemCalendarEventId"] = eventId.toString()
            }
            resMap
        } catch (e: Exception) {
            mapOf("success" to false, "message" to "写入异常: ${e.message}")
        }
    }

    /**
     * 在系统日历中查找是否已存在相同标题与开始时间的日程（精确去重）
     */
    fun findExistingCalendarEventId(context: Context, title: String, startMillis: Long): Long? {
        if (!hasCalendarPermission(context)) return null
        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DTSTART
        )
        val selection = "${CalendarContract.Events.TITLE} = ? AND ${CalendarContract.Events.DTSTART} = ?"
        val selectionArgs = arrayOf(title, startMillis.toString())
        return try {
            context.contentResolver.query(
                CalendarContract.Events.CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getLong(0) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun getOrCreateWritableCalendarId(context: Context): Long? {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
            CalendarContract.Calendars.VISIBLE
        )
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ?",
            arrayOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR.toString()),
            "${CalendarContract.Calendars.IS_PRIMARY} DESC"
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                return cursor.getLong(0)
            }
        }

        val accountName = "anno2agenda_local"
        val values = ContentValues().apply {
            put(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
            put(
                CalendarContract.Calendars.ACCOUNT_TYPE,
                CalendarContract.ACCOUNT_TYPE_LOCAL
            )
            put(CalendarContract.Calendars.NAME, "知程本地日历")
            put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, "知程 AI 日程")
            put(CalendarContract.Calendars.CALENDAR_COLOR, 0xFF2563EB.toInt())
            put(
                CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
                CalendarContract.Calendars.CAL_ACCESS_OWNER
            )
            put(CalendarContract.Calendars.OWNER_ACCOUNT, accountName)
            put(CalendarContract.Calendars.VISIBLE, 1)
            put(CalendarContract.Calendars.SYNC_EVENTS, 1)
            put(CalendarContract.Calendars.CALENDAR_TIME_ZONE, TimeZone.getDefault().id)
        }
        val syncAdapterUri = CalendarContract.Calendars.CONTENT_URI.buildUpon()
            .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
            .appendQueryParameter(
                CalendarContract.Calendars.ACCOUNT_TYPE,
                CalendarContract.ACCOUNT_TYPE_LOCAL
            )
            .build()
        val insertedUri = context.contentResolver.insert(syncAdapterUri, values)
        return insertedUri?.lastPathSegment?.toLongOrNull()
    }

    /**
     * 从系统日历中删除指定事件（实现双向联动同步删除）
     */
    fun deleteFromSystemCalendar(context: Context, eventId: Long): Map<String, Any> {
        if (!hasCalendarPermission(context)) {
            return mapOf(
                "success" to false,
                "message" to "尚未授予日历权限，无法删除系统日历事件",
                "permissionDenied" to true
            )
        }
        return try {
            val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)
            val rows = context.contentResolver.delete(uri, null, null)
            if (rows > 0) {
                mapOf(
                    "success" to true,
                    "message" to "已成功从系统日历删除事件（ID: $eventId）",
                    "rowsAffected" to rows
                )
            } else {
                mapOf(
                    "success" to true,
                    "message" to "系统日历中未找到该事件或此前已被删除（ID: $eventId）",
                    "rowsAffected" to 0
                )
            }
        } catch (e: Exception) {
            mapOf("success" to false, "message" to "删除系统日历事件异常: ${e.message}")
        }
    }

    /**
     * 从系统日历中读取指定时间段内的所有事件（实现反向读取导入）
     */
    fun querySystemCalendarEvents(
        context: Context,
        startMillis: Long,
        endMillis: Long,
        calendarId: Long? = null
    ): Map<String, Any> {
        if (!hasCalendarPermission(context)) {
            return mapOf(
                "success" to false,
                "message" to "尚未授予日历权限，无法读取系统日历",
                "permissionDenied" to true,
                "events" to emptyList<Map<String, Any>>()
            )
        }
        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DESCRIPTION,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.CALENDAR_ID
        )

        val selection = StringBuilder(
            "((${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ?) OR " +
            "(${CalendarContract.Events.DTEND} >= ? AND ${CalendarContract.Events.DTEND} <= ?))"
        )
        val argsList = mutableListOf(
            startMillis.toString(), endMillis.toString(),
            startMillis.toString(), endMillis.toString()
        )

        if (calendarId != null && calendarId > 0) {
            selection.append(" AND ${CalendarContract.Events.CALENDAR_ID} = ?")
            argsList.add(calendarId.toString())
        }

        val eventsList = mutableListOf<Map<String, Any>>()
        return try {
            context.contentResolver.query(
                CalendarContract.Events.CONTENT_URI,
                projection,
                selection.toString(),
                argsList.toTypedArray(),
                "${CalendarContract.Events.DTSTART} ASC"
            )?.use { cursor ->
                val idIdx = cursor.getColumnIndex(CalendarContract.Events._ID)
                val titleIdx = cursor.getColumnIndex(CalendarContract.Events.TITLE)
                val descIdx = cursor.getColumnIndex(CalendarContract.Events.DESCRIPTION)
                val locIdx = cursor.getColumnIndex(CalendarContract.Events.EVENT_LOCATION)
                val startIdx = cursor.getColumnIndex(CalendarContract.Events.DTSTART)
                val endIdx = cursor.getColumnIndex(CalendarContract.Events.DTEND)
                val allDayIdx = cursor.getColumnIndex(CalendarContract.Events.ALL_DAY)
                val calIdIdx = cursor.getColumnIndex(CalendarContract.Events.CALENDAR_ID)

                while (cursor.moveToNext()) {
                    val id = if (idIdx >= 0) cursor.getLong(idIdx) else -1L
                    val title = if (titleIdx >= 0) cursor.getString(titleIdx) ?: "" else ""
                    val desc = if (descIdx >= 0) cursor.getString(descIdx) ?: "" else ""
                    val loc = if (locIdx >= 0) cursor.getString(locIdx) ?: "" else ""
                    val sMillis = if (startIdx >= 0) cursor.getLong(startIdx) else 0L
                    val eMillis = if (endIdx >= 0) cursor.getLong(endIdx) else (sMillis + 3600_000L)
                    val allDay = if (allDayIdx >= 0) cursor.getInt(allDayIdx) == 1 else false
                    val cId = if (calIdIdx >= 0) cursor.getLong(calIdIdx) else 0L

                    if (id > 0 && title.isNotBlank()) {
                        eventsList.add(
                            mapOf(
                                "systemCalendarEventId" to id.toString(),
                                "title" to title,
                                "description" to desc,
                                "location" to loc,
                                "startMillis" to sMillis,
                                "endMillis" to eMillis,
                                "allDay" to allDay,
                                "calendarId" to cId.toString()
                            )
                        )
                    }
                }
            }
            mapOf(
                "success" to true,
                "events" to eventsList,
                "count" to eventsList.size,
                "message" to "已成功读取系统日历 ${eventsList.size} 项日程"
            )
        } catch (e: Exception) {
            mapOf(
                "success" to false,
                "message" to "读取系统日历异常: ${e.message}",
                "events" to emptyList<Map<String, Any>>()
            )
        }
    }

    /**
     * 更新系统日历中的既有事件
     */
    fun updateSystemCalendarEvent(
        context: Context,
        eventId: Long,
        args: Map<*, *>
    ): Map<String, Any> {
        if (!hasCalendarPermission(context)) {
            return mapOf(
                "success" to false,
                "message" to "尚未授予日历权限，无法更新系统日历事件",
                "permissionDenied" to true
            )
        }
        return try {
            val values = ContentValues().apply {
                args["title"]?.toString()?.let { put(CalendarContract.Events.TITLE, it) }
                args["description"]?.toString()?.let { put(CalendarContract.Events.DESCRIPTION, it) }
                args["location"]?.toString()?.let { put(CalendarContract.Events.EVENT_LOCATION, it) }
                (args["startMillis"] as? Number)?.toLong()?.let {
                    put(CalendarContract.Events.DTSTART, it)
                }
                (args["endMillis"] as? Number)?.toLong()?.let {
                    put(CalendarContract.Events.DTEND, it)
                }
            }
            val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)
            val rows = context.contentResolver.update(uri, values, null, null)
            if (rows > 0) {
                mapOf(
                    "success" to true,
                    "message" to "已成功更新系统日历事件（ID: $eventId）",
                    "rowsAffected" to rows
                )
            } else {
                mapOf(
                    "success" to false,
                    "message" to "未在系统日历中找到该事件（ID: $eventId）"
                )
            }
        } catch (e: Exception) {
            mapOf("success" to false, "message" to "更新系统日历事件异常: ${e.message}")
        }
    }

    /**
     * 查询本机所有可用日历账户
     */
    fun querySystemCalendars(context: Context): Map<String, Any> {
        if (!hasCalendarPermission(context)) {
            return mapOf(
                "success" to false,
                "message" to "尚未授予日历权限",
                "permissionDenied" to true,
                "calendars" to emptyList<Map<String, Any>>()
            )
        }
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.CALENDAR_COLOR,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
            CalendarContract.Calendars.VISIBLE,
            CalendarContract.Calendars.IS_PRIMARY
        )
        val calendarsList = mutableListOf<Map<String, Any>>()
        return try {
            context.contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                projection,
                null,
                null,
                "${CalendarContract.Calendars.IS_PRIMARY} DESC, ${CalendarContract.Calendars._ID} ASC"
            )?.use { cursor ->
                val idIdx = cursor.getColumnIndex(CalendarContract.Calendars._ID)
                val accNameIdx = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_NAME)
                val accTypeIdx = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_TYPE)
                val dispNameIdx = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME)
                val colorIdx = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_COLOR)
                val isPrimaryIdx = cursor.getColumnIndex(CalendarContract.Calendars.IS_PRIMARY)

                while (cursor.moveToNext()) {
                    val id = if (idIdx >= 0) cursor.getLong(idIdx) else -1L
                    val accName = if (accNameIdx >= 0) cursor.getString(accNameIdx) ?: "" else ""
                    val accType = if (accTypeIdx >= 0) cursor.getString(accTypeIdx) ?: "" else ""
                    val dispName = if (dispNameIdx >= 0) cursor.getString(dispNameIdx) ?: accName else accName
                    val color = if (colorIdx >= 0) cursor.getInt(colorIdx) else 0
                    val isPrimary = if (isPrimaryIdx >= 0) cursor.getInt(isPrimaryIdx) == 1 else false

                    if (id > 0) {
                        calendarsList.add(
                            mapOf(
                                "id" to id.toString(),
                                "accountName" to accName,
                                "accountType" to accType,
                                "displayName" to dispName,
                                "color" to color,
                                "isPrimary" to isPrimary
                            )
                        )
                    }
                }
            }
            mapOf(
                "success" to true,
                "calendars" to calendarsList,
                "count" to calendarsList.size
            )
        } catch (e: Exception) {
            mapOf("success" to false, "message" to "查询日历账户异常: ${e.message}")
        }
    }
}
