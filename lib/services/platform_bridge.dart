import 'dart:io';
import 'package:flutter/services.dart';
import '../models/agenda_event.dart';
import 'ai_extractor_service.dart';
import 'local_model_manager.dart';

class IncomingCapturePayload {
  final String text;
  final String sourceType; // 'process_text', 'share', 'floating', 'accessibility_screen', 'ocr_screenshot'
  IncomingCapturePayload({required this.text, required this.sourceType});
}

class PlatformBridge {
  static const MethodChannel _channel =
      MethodChannel('com.anno2agenda/native');

  static void Function(IncomingCapturePayload payload)? onExternalCapture;
  static void Function(List<AgendaEvent> events, String engineUsed)?
      onOverlayExtractedEvents;

  /// 初始化原生平台通道监听（Android 划词、分享、悬浮窗原地 AI 提取回调与模型目录获取）
  static Future<void> initialize({
    required void Function(IncomingCapturePayload payload) onCaptureReceived,
    void Function(List<AgendaEvent> events, String engineUsed)?
        onOverlayExtracted,
  }) async {
    onExternalCapture = onCaptureReceived;
    onOverlayExtracted = onOverlayExtracted;
    onOverlayExtractedEvents = onOverlayExtracted;
    if (!Platform.isAndroid) return;

    try {
      final dirPath = await _channel.invokeMethod<String>('getModelsDir');
      if (dirPath != null && dirPath.isNotEmpty) {
        LocalModelManager.setAndroidModelsDir(dirPath);
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
        // 悬浮窗原地识屏/截屏 OCR/剪贴板提取：不切回主界面，直接在后台调用 Flutter AI 引擎
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
        );
        onOverlayExtractedEvents?.call(res.events, res.engineUsed);
        return {
          'engineUsed': res.engineUsed,
          'events': res.events
              .map((e) => {
                    'title': e.title,
                    'location': e.location,
                    'description': [
                      if (e.description.isNotEmpty) e.description,
                      if (e.checklist.isNotEmpty)
                        '待办清单：${e.checklist.join("、")}',
                    ].join('\n'),
                    'startMillis': e.startTime.millisecondsSinceEpoch,
                    'endMillis': e.endTime.millisecondsSinceEpoch,
                    'reminderMinutes': e.reminderMinutes,
                  })
              .toList(),
        };
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

  /// 将日程写入系统日历
  /// - Android: 通过 CalendarContract 静默直写系统日历并设置提醒闹钟
  /// - Windows: 生成标准 .ics 日历文件并唤起 Windows 系统日历导入
  static Future<String> writeEventToSystemCalendar(AgendaEvent event) async {
    if (Platform.isAndroid) {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'insertCalendarEvent',
        {
          'title': event.title,
          'description': [
            if (event.description.isNotEmpty) event.description,
            if (event.checklist.isNotEmpty)
              '待办清单：${event.checklist.join("、")}',
            '--- 提取自通知原文 ---\n${event.sourceText}',
          ].join('\n'),
          'location': event.location,
          'startMillis': event.startTime.millisecondsSinceEpoch,
          'endMillis': event.endTime.millisecondsSinceEpoch,
          'reminderMinutes': event.reminderMinutes,
        },
      );
      final ok = result?['success'] == true;
      final msg = result?['message']?.toString() ??
          (ok ? '已静默写入 Android 系统日历' : '写入日历失败');
      if (!ok) throw Exception(msg);
      return msg;
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
      return '已导出 .ics 并唤起 Windows 日历 (${file.path})';
    }
    return '当前平台暂不支持';
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
}
