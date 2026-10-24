import 'dart:io';
import 'package:flutter/services.dart';
import '../models/agenda_event.dart';
import '../repositories/agenda_repository.dart';
import 'ai_extractor_service.dart';
import 'floating_overlay_service.dart';
import 'local_model_manager.dart';

class IncomingCapturePayload {
  final String text;
  final String sourceType; // 'process_text', 'share', 'floating', 'accessibility_screen', 'ocr_screenshot'
  IncomingCapturePayload({required this.text, required this.sourceType});
}

/// 系统日历底层写入返回实体
class CalendarWriteResult {
  final bool success;
  final String message;
  final String? systemCalendarEventId;
  final bool permissionDenied;

  CalendarWriteResult({
    required this.success,
    required this.message,
    this.systemCalendarEventId,
    this.permissionDenied = false,
  });
}

class PlatformBridge {
  static const MethodChannel _channel =
      MethodChannel('com.anno2agenda/native');

  static void Function(IncomingCapturePayload payload)? onExternalCapture;
  static void Function(List<AgendaEvent> events, String engineUsed)?
      onOverlayExtractedEvents;

  /// 初始化原生平台通道监听（Android 划词、分享、悬浮窗原地 AI 提取回调、悬浮窗写入同步与模型目录获取）
  static Future<void> initialize({
    required void Function(IncomingCapturePayload payload) onCaptureReceived,
    void Function(List<AgendaEvent> events, String engineUsed)?
        onOverlayExtracted,
  }) async {
    onExternalCapture = onCaptureReceived;
    onOverlayExtractedEvents = onOverlayExtracted;
    FloatingOverlayService.instance.onOverlayExtractedEvents =
        onOverlayExtracted;

    if (!Platform.isAndroid) return;

    try {
      final dirPath = await _channel.invokeMethod<String>('getModelsDir');
      if (dirPath != null && dirPath.isNotEmpty) {
        LocalModelManager.setAndroidModelsDir(dirPath);
      }
    } catch (_) {}

    try {
      final storageDir = await getAppStorageDir();
      if (storageDir != null && storageDir.isNotEmpty) {
        await AgendaRepository.instance.init(storageDir: storageDir);
      }
    } catch (_) {}

    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onExternalTextCaptured') {
        final map = Map<String, dynamic>.from(call.arguments as Map);
        final text = map['text']?.toString() ?? '';
        final source = map['sourceType']?.toString() ?? 'process_text';
        if (text.trim().isNotEmpty) {
          onExternalCapture?.call(
            IncomingCapturePayload(text: text.trim(), sourceType: source),
          );
        }
        return null;
      } else if (call.method == 'extractAgendaForOverlay') {
        // 悬浮窗原地识屏/截屏 OCR/剪贴板提取：在后台调用 Flutter AI 引擎并传回完整 AgendaEvent 结构
        final map = Map<String, dynamic>.from(call.arguments as Map);
        final text = map['text']?.toString() ?? '';
        final source = map['sourceType']?.toString() ?? 'floating';
        if (text.trim().isEmpty) {
          return {
            'engineUsed': '空文本',
            'events': <Map<String, dynamic>>[],
          };
        }
        final res = await AIExtractorService.extractFromText(
          rawText: text.trim(),
          sourceType: source,
          mode: AIExtractorService.currentEngineMode,
          llmModelName: AIExtractorService.currentPreferredModel,
          thinkMode: LocalModelManager.enableThinkMode,
        );

        onOverlayExtractedEvents?.call(res.events, res.engineUsed);
        FloatingOverlayService.instance
            .dispatchOverlayExtractedEvents(res.events, res.engineUsed);

        // 回传完整的结构化协议 Map 集合（包含 id、startTime、checklist、confidence 等）
        return {
          'engineUsed': res.engineUsed,
          'events': res.events.map((e) => e.toChannelMap()).toList(),
        };
      } else if (call.method == 'onOverlayAgendaWritten') {
        // 悬浮窗原生写入日历成功后，将事件完整同步进 Flutter 内存与本地仓库
        final rawList = call.arguments as List? ?? [];
        final events = rawList
            .map((item) => AgendaEvent.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList();
        final batchRes = await FloatingOverlayService.instance
            .handleOverlayWrittenEvents(events);
        return {
          'success': batchRes.isAllSuccess,
          'total': batchRes.totalCount,
          'succeeded': batchRes.successCount,
          'failed': batchRes.failureCount,
        };
      } else if (call.method == 'onFloatingWindowStateChanged') {
        final isRunning = call.arguments == true;
        FloatingOverlayService.instance.isRunningNotifier.value = isRunning;
        return true;
      } else if (call.method == 'preloadModelForOverlay') {
        final ok = await LocalModelManager.preloadModel();
        return {
          'success': ok,
          'message': ok ? '端侧大模型已预热就绪' : '预热未完成（未检测到本地模型包）',
          'modelName': LocalModelManager.currentlyLoadedModelId ?? '',
        };
      } else if (call.method == 'isModelReadyForOverlay') {
        final loaded = await LocalModelManager.isModelLoadedInRam();
        return {
          'isLoaded': loaded,
          'isLoading': LocalModelManager.isModelLoading,
          'modelName': LocalModelManager.currentlyLoadedModelId ?? '',
        };
      }
      return null;
    });

    // 检查冷启动时是否有通过划词 (PROCESS_TEXT) 或分享 (ACTION_SEND) 传入的文本
    try {
      final initial = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getInitialCapturedText',
      );
      if (initial != null) {
        final text = initial['text']?.toString() ?? '';
        final source = initial['sourceType']?.toString() ?? 'process_text';
        if (text.trim().isNotEmpty) {
          onExternalCapture?.call(
            IncomingCapturePayload(text: text.trim(), sourceType: source),
          );
        }
      }
    } catch (_) {}
  }

  /// 底层写入日历调用（支持返回事件 ID 与细粒度结果）
  static Future<CalendarWriteResult> writeCalendarEvent(AgendaEvent event) async {
    if (Platform.isAndroid) {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'insertCalendarEvent',
        event.toChannelMap(),
      );
      final ok = result?['success'] == true;
      final msg = result?['message']?.toString() ??
          (ok ? '已静默写入 Android 系统日历' : '写入日历失败');
      final eventId = result?['eventId']?.toString() ??
          result?['systemCalendarEventId']?.toString();
      final permDenied = result?['permissionDenied'] == true;

      return CalendarWriteResult(
        success: ok,
        message: msg,
        systemCalendarEventId: eventId,
        permissionDenied: permDenied,
      );
    } else if (Platform.isWindows) {
      final exportDir = Directory('${Directory.current.path}\\exported_ics');
      if (!exportDir.existsSync()) {
        exportDir.createSync(recursive: true);
      }
      final safeTitle =
          event.title.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
      final file = File('${exportDir.path}\\${safeTitle}_${event.id}.ics');
      await file.writeAsString(event.toIcsString(), flush: true);

      // 调用 Windows 默认关联的日历程序打开 .ics
      await Process.run('cmd', ['/c', 'start', '', file.path]);
      final msg = '已导出 .ics 并唤起 Windows 日历 (${file.path})';
      return CalendarWriteResult(
        success: true,
        message: msg,
        systemCalendarEventId: event.id,
      );
    }
    return CalendarWriteResult(
      success: false,
      message: '当前平台暂不支持直写系统日历',
    );
  }

  /// 将日程写入系统日历（保持既有对外 String 返回值兼容）
  static Future<String> writeEventToSystemCalendar(AgendaEvent event) async {
    final res = await writeCalendarEvent(event);
    if (!res.success) {
      throw Exception(res.message);
    }
    return res.message;
  }

  /// 开启或关闭 Android 全局灵动悬浮窗
  static Future<Map<String, dynamic>> toggleAndroidFloatingWindow(
      bool enable) async {
    if (!Platform.isAndroid) {
      return {'running': false, 'message': '仅 Android 端支持全局悬浮窗'};
    }
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'toggleFloatingWindow',
      {'enable': enable},
    );
    return Map<String, dynamic>.from(res ?? {});
  }

  /// 查询 Android 悬浮窗当前状态
  static Future<bool> isFloatingWindowRunning() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('isFloatingWindowRunning');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 查询 Android 无障碍识屏与静默截屏服务是否已开启
  static Future<bool> isAccessibilityEnabled() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('isAccessibilityEnabled');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开 Android 系统无障碍设置页面
  static Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('openAccessibilitySettings');
    } catch (_) {}
  }

  /// 获取 Android 沙盒应用存储路径（用于跨进程共享 agenda_events.json 持久化文件）
  static Future<String?> getAppStorageDir() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getAppStorageDir');
    } catch (_) {
      return null;
    }
  }
}
