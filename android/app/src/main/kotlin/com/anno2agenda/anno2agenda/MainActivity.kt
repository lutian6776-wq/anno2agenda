package com.anno2agenda.anno2agenda

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.window.OnBackInvokedDispatcher
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.anno2agenda.anno2agenda.floating.FloatingAiGateway
import com.anno2agenda.anno2agenda.floating.FloatingBubbleService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.anno2agenda/native"
        private const val REQ_CALENDAR_PERM = 2001

        /**
         * 供外部通过 MainActivity 兼容调用 FloatingAiGateway 提取日程
         */
        fun extractAgendaForOverlay(
            rawText: String,
            sourceType: String,
            onResult: (List<Map<String, Any>>, String) -> Unit
        ) {
            FloatingAiGateway.extractAgenda(rawText, sourceType) { events, engineInfo ->
                onResult(events.map { it.toMap() }, engineInfo)
            }
        }

        /**
         * 供外部兼容调用大模型预热
         */
        fun preloadModelForOverlay(onResult: (Boolean, String) -> Unit) {
            FloatingAiGateway.preloadModel(onResult)
        }

        /**
         * 供外部兼容查询模型状态
         */
        fun checkModelStatusForOverlay(onResult: (Boolean, Boolean, String) -> Unit) {
            FloatingAiGateway.checkModelStatus(onResult)
        }
    }

    private var methodChannel: MethodChannel? = null
    private var pendingInitialCapture: Map<String, String>? = null
    private var pendingCalendarArgs: Map<*, *>? = null
    private var pendingCalendarResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        extractTextFromIntent(intent, isInitial = true)

        // Android 13+ 预测性返回手势拦截：切后台而非销毁 Activity，保证端侧大模型与 FlutterEngine 常驻后台可被悬浮窗随时拉起
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT
            ) {
                moveTaskToBack(true)
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        moveTaskToBack(true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractTextFromIntent(intent, isInitial = false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel
        FloatingAiGateway.registerChannel(channel)

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialCapturedText" -> {
                    val payload = pendingInitialCapture
                    pendingInitialCapture = null
                    result.success(payload)
                }
                "getAppStorageDir" -> {
                    result.success(filesDir.absolutePath)
                }
                "setThemeMode" -> {
                    val args = call.arguments as? Map<*, *>
                    val mode = args?.get("mode")?.toString() ?: "system"
                    FloatingBubbleService.updateThemeMode(this, mode)
                    result.success(true)
                }
                "onOverlayExtractionProgress" -> {
                    val args = call.arguments as? Map<*, *>
                    val status = args?.get("status")?.toString()
                    if (!status.isNullOrBlank()) {
                        FloatingAiGateway.onProgressUpdate?.invoke(status)
                    }
                    result.success(true)
                }
                "moveTaskToBack" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                "insertCalendarEvent" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.success(mapOf("success" to false, "message" to "参数为空"))
                        return@setMethodCallHandler
                    }
                    if (hasCalendarPermission()) {
                        val res = CalendarWriterHelper.insertIntoSystemCalendar(this, args)
                        result.success(res)
                    } else {
                        pendingCalendarArgs = args
                        pendingCalendarResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(
                                Manifest.permission.READ_CALENDAR,
                                Manifest.permission.WRITE_CALENDAR
                            ),
                            REQ_CALENDAR_PERM
                        )
                    }
                }
                "toggleFloatingWindow" -> {
                    val args = call.arguments as? Map<*, *>
                    val enable = args?.get("enable") == true
                    if (enable) {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                            val settingsIntent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(settingsIntent)
                            result.success(
                                mapOf(
                                    "running" to false,
                                    "message" to "请在弹出的系统设置中授予「显示在其他应用上层」权限后再次点击开启"
                                )
                            )
                        } else {
                            // 顺便检查日历权限，方便后续在悬浮窗内直接一键静默写入日历
                            if (!hasCalendarPermission()) {
                                ActivityCompat.requestPermissions(
                                    this,
                                    arrayOf(
                                        Manifest.permission.READ_CALENDAR,
                                        Manifest.permission.WRITE_CALENDAR
                                    ),
                                    REQ_CALENDAR_PERM
                                )
                            }
                            startService(Intent(this, FloatingBubbleService::class.java))
                            result.success(
                                mapOf(
                                    "running" to true,
                                    "message" to "已开启全局悬浮窗！现在可切换到微信/QQ/浏览器点击悬浮球原地识屏或截屏提取日程"
                                )
                            )
                        }
                    } else {
                        stopService(Intent(this, FloatingBubbleService::class.java))
                        result.success(
                            mapOf(
                                "running" to false,
                                "message" to "已关闭全局悬浮窗"
                            )
                        )
                    }
                }
                "isFloatingWindowRunning" -> {
                    result.success(FloatingBubbleService.isRunning)
                }
                "isAccessibilityEnabled" -> {
                    result.success(ScreenCaptureAccessibilityService.isServiceEnabled)
                }
                "openAccessibilitySettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "getModelsDir" -> {
                    val dir = getExternalFilesDir("models") ?: filesDir.resolve("models")
                    if (!dir.exists()) {
                        dir.mkdirs()
                    }
                    result.success(dir.absolutePath)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        FloatingAiGateway.unregisterChannel(methodChannel)
        super.onDestroy()
    }

    private fun extractTextFromIntent(intent: Intent?, isInitial: Boolean) {
        if (intent == null) return
        var capturedText: String? = null
        var sourceType = "manual"

        when (intent.action) {
            Intent.ACTION_PROCESS_TEXT -> {
                capturedText = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
                sourceType = "process_text"
            }
            Intent.ACTION_SEND -> {
                if (intent.type == "text/plain") {
                    capturedText = intent.getStringExtra(Intent.EXTRA_TEXT)
                    sourceType = "share"
                }
            }
        }

        if (capturedText.isNullOrBlank() && intent.hasExtra(FloatingBubbleService.EXTRA_FLOATING_TEXT)) {
            capturedText = intent.getStringExtra(FloatingBubbleService.EXTRA_FLOATING_TEXT)
            sourceType = "floating"
            intent.removeExtra(FloatingBubbleService.EXTRA_FLOATING_TEXT)
        }

        if (!capturedText.isNullOrBlank()) {
            val payload = mapOf("text" to capturedText.trim(), "sourceType" to sourceType)
            if (isInitial && methodChannel == null) {
                pendingInitialCapture = payload
            } else {
                methodChannel?.invokeMethod("onExternalTextCaptured", payload)
            }
        }
    }

    private fun hasCalendarPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_CALENDAR_PERM) {
            val args = pendingCalendarArgs
            val resCallback = pendingCalendarResult
            pendingCalendarArgs = null
            pendingCalendarResult = null
            if (args != null && resCallback != null) {
                if (hasCalendarPermission()) {
                    resCallback.success(CalendarWriterHelper.insertIntoSystemCalendar(this, args))
                } else {
                    resCallback.success(
                        mapOf(
                            "success" to false,
                            "message" to "未授予日历读写权限，请在系统设置中允许访问日历"
                        )
                    )
                }
            }
        }
    }
}
