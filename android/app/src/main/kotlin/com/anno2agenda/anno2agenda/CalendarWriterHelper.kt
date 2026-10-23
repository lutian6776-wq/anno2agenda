package com.anno2agenda.anno2agenda

import android.Manifest
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
                "message" to "尚未授予日历权限，请先在知程主界面允许日历访问权限"
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

            mapOf(
                "success" to true,
                "message" to "已静默写入系统日历（事件ID: ${eventId ?: "OK"}，提前 ${reminderMinutes} 分钟提醒）"
            )
        } catch (e: Exception) {
            mapOf("success" to false, "message" to "写入异常: ${e.message}")
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
}
