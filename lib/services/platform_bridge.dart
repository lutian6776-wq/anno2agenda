import 'dart:io';
import 'package:flutter/foundation.dart';
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

/// 系统日历底层删除返回实体
class CalendarDeleteResult {
  final bool success;
  final String message;
  final int rowsAffected;
  final bool permissionDenied;

  CalendarDeleteResult({
    required this.success,
    required this.message,
    this.rowsAffected = 0,
    this.permissionDenied = false,
  });
}

/// 从系统日历中读取到的原始事件 DTO
class SystemCalendarEventDto {
  final String systemCalendarEventId;
  final String title;
  final String description;
  final String location;
  final DateTime startTime;
  final DateTime endTime;
  final bool allDay;
  final String calendarId;

  SystemCalendarEventDto({
    required this.systemCalendarEventId,
    required this.title,
    this.description = '',
    this.location = '',
    required this.startTime,
    required this.endTime,
    this.allDay = false,
    this.calendarId = '',
  });

  factory SystemCalendarEventDto.fromMap(Map<dynamic, dynamic> map) {
    final startMs = (map['startMillis'] as num?)?.toInt() ?? 0;
    final endMs = (map['endMillis'] as num?)?.toInt() ?? (startMs + 3600000);
    return SystemCalendarEventDto(
      systemCalendarEventId: map['systemCalendarEventId']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      location: map['location']?.toString() ?? '',
      startTime: DateTime.fromMillisecondsSinceEpoch(startMs),
      endTime: DateTime.fromMillisecondsSinceEpoch(endMs),
      allDay: map['allDay'] == true,
      calendarId: map['calendarId']?.toString() ?? '',
    );
  }

  /// 将读取到的系统日历事件转换为知程 AgendaEvent 标准模型
  AgendaEvent toAgendaEvent() {
    return AgendaEvent(
      id: 'syscal_${systemCalendarEventId}_${startTime.millisecondsSinceEpoch}',
      title: title.isEmpty ? '系统日历事项' : title,
      startTime: startTime,
      endTime: endTime,
      location: location,
      description: description,
      sourceText: '从系统日历导入: $title',
      sourceType: 'system_calendar',
      reminderMinutes: 30,
      confidence: 1.0,
      syncedToSystemCalendar: true,
      systemCalendarEventId: systemCalendarEventId,
      deviceOrigin: Platform.isAndroid ? 'android' : 'windows',
    );
  }
}

/// 系统日历账户信息 DTO
class SystemCalendarAccountDto {
  final String id;
  final String accountName;
  final String accountType;
  final String displayName;
  final int color;
  final bool isPrimary;

  SystemCalendarAccountDto({
    required this.id,
    required this.accountName,
    required this.accountType,
    required this.displayName,
    this.color = 0,
    this.isPrimary = false,
  });

  factory SystemCalendarAccountDto.fromMap(Map<dynamic, dynamic> map) {
    return SystemCalendarAccountDto(
      id: map['id']?.toString() ?? '',
      accountName: map['accountName']?.toString() ?? '',
      accountType: map['accountType']?.toString() ?? '',
      displayName: map['displayName']?.toString() ?? '',
      color: (map['color'] as num?)?.toInt() ?? 0,
      isPrimary: map['isPrimary'] == true,
    );
  }
}

class PlatformBridge {
  static const MethodChannel _channel =
      MethodChannel('com.anno2agenda/native');

  /// 仅用于测试：强制走 Native MethodChannel 逻辑（模拟 Android 环境）
  static bool debugForceNativeChannel = false;

  static void Function(IncomingCapturePayload payload)? onExternalCapture;
  static void Function(List<AgendaEvent> events, String engineUsed)?
      onOverlayExtractedEvents;
  static Future<ExtractionResult> Function(String text, String sourceType)?
      onOverlayExtractRequest;

  /// 初始化原生平台通道监听（Android 划词、分享、悬浮窗原地 AI 提取回调、悬浮窗写入同步与模型目录获取）
  static Future<void> initialize({
    required void Function(IncomingCapturePayload payload) onCaptureReceived,
    void Function(List<AgendaEvent> events, String engineUsed)?
        onOverlayExtracted,
    Future<ExtractionResult> Function(String text, String sourceType)?
        onOverlayExtract,
  }) async {
    onExternalCapture = onCaptureReceived;
    onOverlayExtractedEvents = onOverlayExtracted;
    onOverlayExtractRequest = onOverlayExtract;
    FloatingOverlayService.instance.onOverlayExtractedEvents =
        onOverlayExtracted;

    if (!Platform.isAndroid) return;

    await ensureModelsDir();

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
        // 悬浮窗原地识屏/截屏 OCR/剪贴板/手动解析：直接拉起主程序 AI 提取管线并回传结构化结果
        final map = Map<String, dynamic>.from(call.arguments as Map);
        final text = map['text']?.toString() ?? '';
        final source = map['sourceType']?.toString() ?? 'floating';
        if (text.trim().isEmpty) {
          return {
            'engineUsed': '空文本',
            'events': <Map<String, dynamic>>[],
          };
        }

        await ensureModelsDir();

        final ExtractionResult res;
        if (onOverlayExtractRequest != null) {
          res = await onOverlayExtractRequest!(text.trim(), source);
        } else {
          res = await AIExtractorService.extractFromText(
            rawText: text.trim(),
            sourceType: source,
            mode: AIExtractorService.currentEngineMode,
            llmEndpoint: AIExtractorService.currentLlmEndpoint,
            llmModelName: AIExtractorService.currentPreferredModel,
            thinkMode: LocalModelManager.enableThinkMode,
            onProgress: ({stepLog, token, tokenCount}) {
              if (tokenCount != null && tokenCount % 8 == 1) {
                sendOverlayProgress('🧠 端侧大模型生成中 (已输出 $tokenCount tokens)...');
              } else if (stepLog != null) {
                sendOverlayProgress('⏳ $stepLog');
              }
            },
          );
          onOverlayExtractedEvents?.call(res.events, res.engineUsed);
        }

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
    if (Platform.isAndroid || debugForceNativeChannel) {
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

  /// 从系统日历中删除指定事件（实现双向联动同步删除）
  static Future<CalendarDeleteResult> deleteCalendarEvent(
      String systemCalendarEventId) async {
    if (systemCalendarEventId.trim().isEmpty) {
      return CalendarDeleteResult(
        success: false,
        message: '系统日历事件 ID 为空',
      );
    }

    if (Platform.isAndroid || debugForceNativeChannel) {
      try {
        final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'deleteCalendarEvent',
          {'systemCalendarEventId': systemCalendarEventId},
        );
        final ok = result?['success'] == true;
        final msg = result?['message']?.toString() ??
            (ok ? '已从 Android 系统日历删除' : '删除系统日历事件失败');
        final rows = (result?['rowsAffected'] as num?)?.toInt() ?? (ok ? 1 : 0);
        final permDenied = result?['permissionDenied'] == true;

        return CalendarDeleteResult(
          success: ok,
          message: msg,
          rowsAffected: rows,
          permissionDenied: permDenied,
        );
      } catch (e) {
        return CalendarDeleteResult(
          success: false,
          message: '删除系统日历事件异常: $e',
        );
      }
    } else if (Platform.isWindows) {
      try {
        final exportDir = Directory('${Directory.current.path}\\exported_ics');
        if (exportDir.existsSync()) {
          var deletedCount = 0;
          for (final f in exportDir.listSync()) {
            if (f is File && f.path.endsWith('.ics')) {
              if (f.path.contains(systemCalendarEventId)) {
                f.deleteSync();
                deletedCount++;
              }
            }
          }
          return CalendarDeleteResult(
            success: true,
            message: '已删除 Windows 导出的 .ics 日历文件 ($deletedCount 项)',
            rowsAffected: deletedCount,
          );
        }
        return CalendarDeleteResult(
          success: true,
          message: '本地日历导出目录不存在，无需清理',
          rowsAffected: 0,
        );
      } catch (e) {
        return CalendarDeleteResult(
          success: false,
          message: '清理 Windows .ics 异常: $e',
        );
      }
    }
    return CalendarDeleteResult(
      success: false,
      message: '当前平台暂不支持联动删除系统日历',
    );
  }

  /// 从系统日历中读取指定时间段的所有事件（实现反向读取导入）
  static Future<List<SystemCalendarEventDto>> fetchSystemCalendarEvents({
    required DateTime startTime,
    required DateTime endTime,
    String? calendarId,
  }) async {
    if (Platform.isAndroid || debugForceNativeChannel) {
      try {
        final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'getCalendarEvents',
          {
            'startMillis': startTime.millisecondsSinceEpoch,
            'endMillis': endTime.millisecondsSinceEpoch,
            if (calendarId != null && calendarId.isNotEmpty)
              'calendarId': calendarId,
          },
        );
        final rawEvents = result?['events'] as List<dynamic>? ?? [];
        return rawEvents
            .map((e) => SystemCalendarEventDto.fromMap(
                Map<dynamic, dynamic>.from(e as Map)))
            .toList();
      } catch (e) {
        debugPrint('[PlatformBridge] 获取系统日历事件失败: $e');
        return [];
      }
    } else if (Platform.isWindows) {
      try {
        final list = <SystemCalendarEventDto>[];
        final exportDir = Directory('${Directory.current.path}\\exported_ics');
        if (exportDir.existsSync()) {
          for (final entity in exportDir.listSync()) {
            if (entity is File && entity.path.endsWith('.ics')) {
              final content = entity.readAsStringSync();
              final event = AgendaEvent.fromIcsString(content);
              if (event != null &&
                  event.endTime.isAfter(startTime) &&
                  event.startTime.isBefore(endTime)) {
                list.add(SystemCalendarEventDto(
                  systemCalendarEventId: event.id,
                  title: event.title,
                  description: event.description,
                  location: event.location,
                  startTime: event.startTime,
                  endTime: event.endTime,
                  calendarId: 'windows_ics',
                ));
              }
            }
          }
        }
        return list;
      } catch (e) {
        debugPrint('[PlatformBridge] 读取 Windows 导出 .ics 失败: $e');
        return [];
      }
    }
    return [];
  }

  /// 更新系统日历中的事件
  static Future<CalendarWriteResult> updateCalendarEvent(
      AgendaEvent event) async {
    if (event.systemCalendarEventId == null ||
        event.systemCalendarEventId!.isEmpty) {
      return writeCalendarEvent(event);
    }

    if (Platform.isAndroid || debugForceNativeChannel) {
      try {
        final map = event.toChannelMap();
        map['eventId'] = event.systemCalendarEventId;
        final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'updateCalendarEvent',
          map,
        );
        final ok = result?['success'] == true;
        final msg = result?['message']?.toString() ??
            (ok ? '已更新 Android 系统日历' : '更新系统日历失败');
        final permDenied = result?['permissionDenied'] == true;

        return CalendarWriteResult(
          success: ok,
          message: msg,
          systemCalendarEventId: event.systemCalendarEventId,
          permissionDenied: permDenied,
        );
      } catch (e) {
        return CalendarWriteResult(
          success: false,
          message: '更新系统日历异常: $e',
          systemCalendarEventId: event.systemCalendarEventId,
        );
      }
    } else if (Platform.isWindows) {
      return writeCalendarEvent(event);
    }
    return CalendarWriteResult(
      success: false,
      message: '当前平台暂不支持更新系统日历',
    );
  }

  /// 查询系统可用日历账户
  static Future<List<SystemCalendarAccountDto>> getSystemCalendars() async {
    if (Platform.isAndroid || debugForceNativeChannel) {
      try {
        final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'getSystemCalendars',
        );
        final rawList = result?['calendars'] as List<dynamic>? ?? [];
        return rawList
            .map((c) => SystemCalendarAccountDto.fromMap(
                Map<dynamic, dynamic>.from(c as Map)))
            .toList();
      } catch (e) {
        debugPrint('[PlatformBridge] 获取日历账户列表失败: $e');
        return [];
      }
    } else if (Platform.isWindows) {
      return [
        SystemCalendarAccountDto(
          id: 'windows_ics',
          accountName: 'Windows 本地日历',
          accountType: 'local_ics',
          displayName: '知程导出日历 (ICS)',
          isPrimary: true,
        )
      ];
    }
    return [];
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

  /// 确保 Android 模型目录路径已注入 LocalModelManager
  static Future<String?> ensureModelsDir() async {
    if (!Platform.isAndroid) return null;
    try {
      final dirPath = await _channel.invokeMethod<String>('getModelsDir');
      if (dirPath != null && dirPath.isNotEmpty) {
        LocalModelManager.setAndroidModelsDir(dirPath);
        return dirPath;
      }
    } catch (_) {}
    return null;
  }

  /// 将当前应用的深浅色主题同步给 Android 原生灵动悬浮窗
  static Future<void> syncThemeMode(String mode) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('setThemeMode', {'mode': mode});
    } catch (_) {}
  }

  /// 将主程序端侧大模型推理进度实时推送给悬浮窗状态栏
  static Future<void> sendOverlayProgress(String status) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>(
        'onOverlayExtractionProgress',
        {'status': status},
      );
    } catch (_) {}
  }

  /// 将 Android 主活动退至后台而不销毁引擎
  static Future<void> moveTaskToBack() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('moveTaskToBack');
    } catch (_) {}
  }
}
