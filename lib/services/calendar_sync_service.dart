import 'package:flutter/foundation.dart';
import '../models/agenda_event.dart';
import '../repositories/agenda_repository.dart';
import 'agenda_write_service.dart';
import 'platform_bridge.dart';

enum CalendarSyncDirection {
  twoWay, // 双向对齐（拉取 + 推送 + 同步删除检测）
  pullOnly, // 仅从系统日历导入
  pushOnly, // 仅推送到系统日历
}

enum CalendarTimeSpanOption {
  oneMonth('近 1 个月', Duration(days: 30)),
  threeMonths('前后 3 个月', Duration(days: 90)),
  sixMonths('前后 6 个月', Duration(days: 180)),
  all('全部日程', Duration(days: 365 * 2));

  final String label;
  final Duration duration;
  const CalendarTimeSpanOption(this.label, this.duration);
}

class CalendarSyncOptions {
  final CalendarSyncDirection direction;
  final CalendarTimeSpanOption timeSpan;
  final String? calendarId;
  final bool autoDeleteSystemWhenAppDeleted;
  final bool removeAppEventIfDeletedInSystem;

  const CalendarSyncOptions({
    this.direction = CalendarSyncDirection.twoWay,
    this.timeSpan = CalendarTimeSpanOption.threeMonths,
    this.calendarId,
    this.autoDeleteSystemWhenAppDeleted = true,
    this.removeAppEventIfDeletedInSystem = false,
  });
}

class CalendarSyncResult {
  final bool success;
  final String message;
  final int pulledCount;
  final int pushedCount;
  final int updatedCount;
  final int deletedCount;
  final int unchangedCount;
  final List<String> errorLogs;
  final DateTime completedAt;

  CalendarSyncResult({
    required this.success,
    required this.message,
    this.pulledCount = 0,
    this.pushedCount = 0,
    this.updatedCount = 0,
    this.deletedCount = 0,
    this.unchangedCount = 0,
    List<String>? errorLogs,
    DateTime? completedAt,
  })  : errorLogs = errorLogs ?? [],
        completedAt = completedAt ?? DateTime.now();

  String get summary {
    if (!success) return message;
    final parts = <String>[];
    if (pulledCount > 0) parts.add('导入 $pulledCount 项');
    if (pushedCount > 0) parts.add('推送 $pushedCount 项');
    if (updatedCount > 0) parts.add('更新 $updatedCount 项');
    if (deletedCount > 0) parts.add('清理 $deletedCount 项');
    if (parts.isEmpty) {
      return '所有日程已是最新，无变动项 (已有 $unchangedCount 项已同步)';
    }
    return '同步完成：${parts.join("，")}';
  }
}

/// 系统日历双向同步核心服务 (Two-Way System Calendar Sync Service)
class CalendarSyncService {
  final IAgendaRepository _repo;

  CalendarSyncService({IAgendaRepository? repo})
      : _repo = repo ?? AgendaRepository.instance;

  static final CalendarSyncService instance = CalendarSyncService();

  final ValueNotifier<bool> isSyncingNotifier = ValueNotifier<bool>(false);
  CalendarSyncResult? lastResult;

  /// 执行双向/单向日历智能同步
  Future<CalendarSyncResult> performTwoWaySync({
    CalendarSyncOptions options = const CalendarSyncOptions(),
  }) async {
    if (isSyncingNotifier.value) {
      return CalendarSyncResult(
        success: false,
        message: '当前已有日历同步任务正在执行中，请稍候...',
      );
    }

    isSyncingNotifier.value = true;
    final errorLogs = <String>[];
    int pulled = 0;
    int pushed = 0;
    int updated = 0;
    int deleted = 0;
    int unchanged = 0;

    try {
      final now = DateTime.now();
      final startTime = now.subtract(options.timeSpan.duration);
      final endTime = now.add(options.timeSpan.duration);

      // ================= 阶段 1：拉取并解析系统日历 (Pull) =================
      final systemEventsMap = <String, SystemCalendarEventDto>{};

      if (options.direction != CalendarSyncDirection.pushOnly) {
        final sysEvents = await PlatformBridge.fetchSystemCalendarEvents(
          startTime: startTime,
          endTime: endTime,
          calendarId: options.calendarId,
        );

        for (final dto in sysEvents) {
          systemEventsMap[dto.systemCalendarEventId] = dto;

          // 1. 根据系统日历事件 ID 探测本地是否已有
          var local =
              _repo.getEventBySystemCalendarId(dto.systemCalendarEventId);

          // 2. 若未根据 ID 找到，尝试按三要素（标题+时间+地点）查重
          final asEvent = dto.toAgendaEvent();
          local ??= _repo.findDuplicate(asEvent);

          if (local == null) {
            // 本地没有该日程 -> 作为新日程导入入库
            await _repo.addEvent(asEvent);
            pulled++;
          } else {
            // 本地已有该日程：核实并补充系统日历关联标记
            bool needsUpdate = false;
            if (!local.syncedToSystemCalendar ||
                local.systemCalendarEventId != dto.systemCalendarEventId) {
              local.syncedToSystemCalendar = true;
              local.systemCalendarEventId = dto.systemCalendarEventId;
              needsUpdate = true;
            }

            // 比对内容是否有修改（以系统日历中的最新信息为准）
            if (local.title != dto.title && dto.title.isNotEmpty) {
              local.title = dto.title;
              needsUpdate = true;
            }
            if ((local.startTime.difference(dto.startTime).inSeconds).abs() >
                60) {
              local.startTime = dto.startTime;
              local.endTime = dto.endTime;
              needsUpdate = true;
            }
            if (local.location != dto.location && dto.location.isNotEmpty) {
              local.location = dto.location;
              needsUpdate = true;
            }

            if (needsUpdate) {
              await _repo.updateEvent(local);
              updated++;
            } else {
              unchanged++;
            }
          }
        }
      }

      // ================= 阶段 2：推送本地未同步日程到系统日历 (Push) =================
      if (options.direction != CalendarSyncDirection.pullOnly) {
        final allLocal = _repo.allEvents;
        for (final local in allLocal) {
          // 只检查在当前同步时间范围内的日程
          if (local.endTime.isBefore(startTime) ||
              local.startTime.isAfter(endTime)) {
            continue;
          }

          if (!local.syncedToSystemCalendar ||
              local.systemCalendarEventId == null ||
              local.systemCalendarEventId!.isEmpty) {
            // 未同步到系统日历：推送写入
            final writeRes = await AgendaWriteService.instance.writeEvent(
              local,
              writeToSystemCalendar: true,
            );
            if (writeRes.success) {
              pushed++;
            } else {
              errorLogs.add('推送日程「${local.title}」失败: ${writeRes.message}');
            }
          } else {
            // 已同步到系统日历：检查在系统端是否存在
            final inSys =
                systemEventsMap.containsKey(local.systemCalendarEventId);
            if (!inSys &&
                systemEventsMap.isNotEmpty &&
                options.direction == CalendarSyncDirection.twoWay) {
              // 说明在系统日历中已被外部物理删除
              if (options.removeAppEventIfDeletedInSystem) {
                await _repo.removeEvent(local.id);
                deleted++;
              } else {
                // 重置本地同步状态，保留本地事项但标记为待重新同步
                local.syncedToSystemCalendar = false;
                local.systemCalendarEventId = null;
                await _repo.updateEvent(local);
                deleted++;
              }
            }
          }
        }
      }

      final res = CalendarSyncResult(
        success: true,
        message: '双向同步完成',
        pulledCount: pulled,
        pushedCount: pushed,
        updatedCount: updated,
        deletedCount: deleted,
        unchangedCount: unchanged,
        errorLogs: errorLogs,
      );
      lastResult = res;
      return res;
    } catch (e) {
      final res = CalendarSyncResult(
        success: false,
        message: '双向同步异常: $e',
        errorLogs: [e.toString()],
      );
      lastResult = res;
      return res;
    } finally {
      isSyncingNotifier.value = false;
    }
  }

  /// 带系统日历联动删除的日程删除方法
  Future<CalendarDeleteResult> deleteEventWithSync(
    AgendaEvent event, {
    bool deleteFromSystem = true,
  }) async {
    CalendarDeleteResult? calDeleteRes;

    // 1. 若要求同步删除系统日历，且该日程具有已关联的系统事件 ID
    if (deleteFromSystem &&
        event.syncedToSystemCalendar &&
        event.systemCalendarEventId != null &&
        event.systemCalendarEventId!.isNotEmpty) {
      try {
        calDeleteRes = await PlatformBridge.deleteCalendarEvent(
          event.systemCalendarEventId!,
        );
      } catch (e) {
        calDeleteRes = CalendarDeleteResult(
          success: false,
          message: '调用系统日历删除异常: $e',
        );
      }
    }

    // 2. 从本地仓储移除
    await _repo.removeEvent(event.id);

    return calDeleteRes ??
        CalendarDeleteResult(
          success: true,
          message: '已从应用日程中移除',
          rowsAffected: 1,
        );
  }

  /// 批量将本地未同步日程推向系统日历
  Future<AgendaBatchWriteResult> pushAllUnsyncedEvents() async {
    final unsynced =
        _repo.allEvents.where((e) => !e.syncedToSystemCalendar).toList();
    return AgendaWriteService.instance.writeEvents(
      unsynced,
      writeToSystemCalendar: true,
    );
  }
}
