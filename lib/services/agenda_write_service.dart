import 'package:flutter/foundation.dart';
import '../models/agenda_event.dart';
import '../repositories/agenda_repository.dart';
import 'platform_bridge.dart';

/// 单条日程写入执行结果
class AgendaWriteResult {
  final String eventId;
  final bool success;
  final String message;
  final bool persisted;
  final String? systemCalendarEventId;
  final AgendaEvent event;

  AgendaWriteResult({
    required this.eventId,
    required this.success,
    required this.message,
    required this.persisted,
    this.systemCalendarEventId,
    required this.event,
  });

  Map<String, dynamic> toJson() => {
        'eventId': eventId,
        'success': success,
        'message': message,
        'persisted': persisted,
        'systemCalendarEventId': systemCalendarEventId,
      };

  @override
  String toString() =>
      'AgendaWriteResult(id: $eventId, success: $success, persisted: $persisted, msg: $message, sysCalId: $systemCalendarEventId)';
}

/// 批量日程写入统计结果
class AgendaBatchWriteResult {
  final List<AgendaWriteResult> results;
  final int totalCount;
  final int successCount;
  final int failureCount;

  AgendaBatchWriteResult({required this.results})
      : totalCount = results.length,
        successCount = results.where((r) => r.success).length,
        failureCount = results.where((r) => !r.success).length;

  bool get isAllSuccess => failureCount == 0;
  bool get hasFailure => failureCount > 0;

  String get summaryMessage {
    if (totalCount == 0) return '没有需要写入的日程';
    if (isAllSuccess) return '已成功写入 $totalCount 项日程并保存至本地';
    return '共处理 $totalCount 项日程：成功 $successCount 项，失败 $failureCount 项';
  }
}

/// 统一日程写入核心业务服务 (Unified Agenda Write Business Service)
///
/// 贯穿应用内主工作台、我的日程页面、局域网协同以及 Android 全局悬浮窗的原生直写。
/// 提供严格的 ID/内容去重、本地仓库持久化与系统日历 Provider 同步。
class AgendaWriteService {
  final IAgendaRepository _repo;

  AgendaWriteService({IAgendaRepository? repo})
      : _repo = repo ?? AgendaRepository.instance;

  static final AgendaWriteService instance = AgendaWriteService();

  /// 写入单个日程
  /// - [event]: 待写入的标准日程对象
  /// - [writeToSystemCalendar]: 是否同步写入底层操作系统日历（Android CalendarContract 或 Windows .ics）
  Future<AgendaWriteResult> writeEvent(
    AgendaEvent event, {
    bool writeToSystemCalendar = true,
  }) async {
    // 1. 去重检查：优先根据 ID 去重，若无则检查核心三要素（标题、时间、地点）
    final existing = _repo.findDuplicate(event);

    var effectiveEvent = event;
    if (existing != null) {
      // 若本地已存在，继承历史 ID 与已同步的系统日历 ID
      effectiveEvent = event.copyWith(
        id: existing.id,
        syncedToSystemCalendar:
            event.syncedToSystemCalendar || existing.syncedToSystemCalendar,
        systemCalendarEventId: event.systemCalendarEventId ??
            existing.systemCalendarEventId,
      );
    }

    // 2. 如果不要求写入系统日历，直接入库
    if (!writeToSystemCalendar) {
      try {
        await _repo.addEvent(effectiveEvent);
        return AgendaWriteResult(
          eventId: effectiveEvent.id,
          success: true,
          message: '已保存至本地日程库',
          persisted: true,
          systemCalendarEventId: effectiveEvent.systemCalendarEventId,
          event: effectiveEvent,
        );
      } catch (e) {
        return AgendaWriteResult(
          eventId: effectiveEvent.id,
          success: false,
          message: '本地持久化失败: $e',
          persisted: false,
          event: effectiveEvent,
        );
      }
    }

    // 3. 需写入系统日历：检查是否已经同步过系统日历
    if (effectiveEvent.syncedToSystemCalendar) {
      // 已经写入过系统日历，直接更新本地数据，避免向系统日历插入重复事件
      try {
        await _repo.addEvent(effectiveEvent);
        return AgendaWriteResult(
          eventId: effectiveEvent.id,
          success: true,
          message: '日程此前已同步至系统日历，已自动更新本地记录，避免重复写入',
          persisted: true,
          systemCalendarEventId: effectiveEvent.systemCalendarEventId,
          event: effectiveEvent,
        );
      } catch (e) {
        return AgendaWriteResult(
          eventId: effectiveEvent.id,
          success: false,
          message: '本地保存失败: $e',
          persisted: false,
          systemCalendarEventId: effectiveEvent.systemCalendarEventId,
          event: effectiveEvent,
        );
      }
    }

    // 4. 调用原生底层日历写入
    CalendarWriteResult calRes;
    try {
      calRes = await PlatformBridge.writeCalendarEvent(effectiveEvent);
    } catch (e) {
      calRes = CalendarWriteResult(
        success: false,
        message: '调用系统日历异常: $e',
      );
    }

    if (calRes.success) {
      effectiveEvent.syncedToSystemCalendar = true;
      if (calRes.systemCalendarEventId != null &&
          calRes.systemCalendarEventId!.isNotEmpty) {
        effectiveEvent.systemCalendarEventId = calRes.systemCalendarEventId;
      }

      // 5. 将写入结果保存至本地仓储
      try {
        await _repo.addEvent(effectiveEvent);
        return AgendaWriteResult(
          eventId: effectiveEvent.id,
          success: true,
          message: calRes.message,
          persisted: true,
          systemCalendarEventId: effectiveEvent.systemCalendarEventId,
          event: effectiveEvent,
        );
      } catch (e) {
        debugPrint('[AgendaWriteService] 系统日历写入成功但本地保存失败: $e');
        return AgendaWriteResult(
          eventId: effectiveEvent.id,
          success: false,
          message: '已写入系统日历，但本地持久化失败: $e',
          persisted: false,
          systemCalendarEventId: effectiveEvent.systemCalendarEventId,
          event: effectiveEvent,
        );
      }
    } else {
      // 日历写入失败（如缺少日历权限）：仍保留到本地仓储但标记为未同步，便于用户后续手动重试
      try {
        effectiveEvent.syncedToSystemCalendar = false;
        await _repo.addEvent(effectiveEvent);
        return AgendaWriteResult(
          eventId: effectiveEvent.id,
          success: false,
          message: calRes.message,
          persisted: true,
          systemCalendarEventId: null,
          event: effectiveEvent,
        );
      } catch (e) {
        return AgendaWriteResult(
          eventId: effectiveEvent.id,
          success: false,
          message: '日历写入失败: ${calRes.message}；本地保存亦失败: $e',
          persisted: false,
          event: effectiveEvent,
        );
      }
    }
  }

  /// 批量写入日程
  Future<AgendaBatchWriteResult> writeEvents(
    List<AgendaEvent> events, {
    bool writeToSystemCalendar = true,
  }) async {
    final results = <AgendaWriteResult>[];
    for (final ev in events) {
      final res = await writeEvent(
        ev,
        writeToSystemCalendar: writeToSystemCalendar,
      );
      results.add(res);
    }
    return AgendaBatchWriteResult(results: results);
  }

  /// 同步原生悬浮窗已经写入完成的日程集合到本地仓储中
  ///
  /// 当 Android 原生悬浮窗在非 Flutter 界面中一键静默写入系统日历后，
  /// 会将带有最新 systemCalendarEventId 的完整 AgendaEvent 传回。
  /// 此方法进行去重入库、持久化并更新所有页面状态。
  Future<AgendaBatchWriteResult> syncOverlayWrittenEvents(
    List<AgendaEvent> events,
  ) async {
    final results = <AgendaWriteResult>[];
    for (final ev in events) {
      try {
        final existing = _repo.findDuplicate(ev);
        final toSave = ev.copyWith(
          id: existing?.id ?? ev.id,
          syncedToSystemCalendar: true,
          systemCalendarEventId: ev.systemCalendarEventId ??
              existing?.systemCalendarEventId,
        );
        await _repo.addEvent(toSave);
        results.add(AgendaWriteResult(
          eventId: toSave.id,
          success: true,
          message: '悬浮窗日程已同步至应用内部仓储',
          persisted: true,
          systemCalendarEventId: toSave.systemCalendarEventId,
          event: toSave,
        ));
      } catch (e) {
        results.add(AgendaWriteResult(
          eventId: ev.id,
          success: false,
          message: '悬浮窗日程本地入库失败: $e',
          persisted: false,
          systemCalendarEventId: ev.systemCalendarEventId,
          event: ev,
        ));
      }
    }
    return AgendaBatchWriteResult(results: results);
  }
}
