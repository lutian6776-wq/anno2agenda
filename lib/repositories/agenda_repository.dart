import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/agenda_event.dart';
import 'i_agenda_repository.dart';

export 'i_agenda_repository.dart';

class AgendaRepository implements IAgendaRepository {
  static final AgendaRepository _instance = AgendaRepository._internal();
  factory AgendaRepository() => _instance;
  static AgendaRepository get instance => _instance;

  AgendaRepository._internal();

  final List<AgendaEvent> _events = [];
  @override
  final ValueNotifier<List<AgendaEvent>> eventsNotifier =
      ValueNotifier<List<AgendaEvent>>([]);

  File? _storageFile;

  /// 获取所有日程只读列表（按开始时间升序排列）
  @override
  List<AgendaEvent> get allEvents => List.unmodifiable(_events);

  /// 初始化本地持久化仓储并加载历史日程
  @override
  Future<void> init({String? storageDir}) async {
    try {
      String baseDir = storageDir ?? '';
      if (baseDir.isEmpty) {
        baseDir = Directory.current.path;
      }
      final file = File('$baseDir/agenda_events.json');
      _storageFile = file;

      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final loaded = AgendaEvent.decodeList(content);
          _events.clear();
          _events.addAll(loaded);
          _sortEvents();
          _notify();
        }
      }
    } catch (e) {
      debugPrint('[AgendaRepository] 加载本地日程失败: $e');
    }
  }

  /// 重新从本地存储文件读取最新日程（例如悬浮窗在后台写入后触发同步）
  @override
  Future<void> reload() async {
    try {
      final file = _storageFile;
      if (file != null && await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final loaded = AgendaEvent.decodeList(content);
          _events.clear();
          _events.addAll(loaded);
          _sortEvents();
          _notify();
        }
      }
    } catch (e) {
      debugPrint('[AgendaRepository] 重新加载本地日程失败: $e');
    }
  }

  /// 根据 ID 精确查找日程
  @override
  AgendaEvent? getEventById(String id) {
    final idx = _events.indexWhere((e) => e.id == id);
    return idx >= 0 ? _events[idx] : null;
  }

  /// 根据 ID 或核心三要素（标题、开始时间、地点）探测是否存在重复日程
  @override
  AgendaEvent? findDuplicate(AgendaEvent event) {
    for (final e in _events) {
      if (e.id == event.id) return e;
      final sameTitle = e.title.trim() == event.title.trim();
      final sameLocation = e.location.trim() == event.location.trim();
      final diffSeconds = (e.startTime.difference(event.startTime).inSeconds).abs();
      if (sameTitle && sameLocation && diffSeconds <= 60) {
        return e;
      }
    }
    return null;
  }

  /// 添加单个日程
  @override
  Future<void> addEvent(AgendaEvent event) async {
    final existingIdx = _events.indexWhere((e) => e.id == event.id);
    if (existingIdx >= 0) {
      _events[existingIdx] = event;
    } else {
      _events.add(event);
    }
    _sortEvents();
    _notify();
    await _persist();
  }

  /// 批量添加日程
  @override
  Future<void> addEvents(List<AgendaEvent> events) async {
    for (final ev in events) {
      final existingIdx = _events.indexWhere((e) => e.id == ev.id);
      if (existingIdx >= 0) {
        _events[existingIdx] = ev;
      } else {
        _events.add(ev);
      }
    }
    _sortEvents();
    _notify();
    await _persist();
  }

  /// 删除单个日程
  @override
  Future<void> removeEvent(String id) async {
    _events.removeWhere((e) => e.id == id);
    _notify();
    await _persist();
  }

  /// 清空所有日程
  @override
  Future<void> clearAll() async {
    _events.clear();
    _notify();
    await _persist();
  }

  /// 更新日程
  @override
  Future<void> updateEvent(AgendaEvent event) async {
    final idx = _events.indexWhere((e) => e.id == event.id);
    if (idx >= 0) {
      _events[idx] = event;
      _sortEvents();
      _notify();
      await _persist();
    }
  }

  /// 标记日程为已写入系统日历
  @override
  Future<void> markAsSynced(String id, {String? systemCalendarEventId}) async {
    final idx = _events.indexWhere((e) => e.id == id);
    if (idx >= 0) {
      _events[idx].syncedToSystemCalendar = true;
      if (systemCalendarEventId != null && systemCalendarEventId.isNotEmpty) {
        _events[idx].systemCalendarEventId = systemCalendarEventId;
      }
      _notify();
      await _persist();
    }
  }

  /// 合并远端设备（局域网同步）同步过来的日程
  @override
  Future<List<AgendaEvent>> mergeRemoteEvents(List<AgendaEvent> remote) async {
    final map = <String, AgendaEvent>{};
    for (final e in _events) {
      map[e.id] = e;
    }
    for (final r in remote) {
      if (!map.containsKey(r.id)) {
        map[r.id] = r;
      } else {
        // 若远端已同步到日历，则更新同步状态
        if (r.syncedToSystemCalendar) {
          map[r.id]!.syncedToSystemCalendar = true;
        }
      }
    }
    _events.clear();
    _events.addAll(map.values);
    _sortEvents();
    _notify();
    await _persist();
    return allEvents;
  }

  /// 条件查询与过滤
  @override
  List<AgendaEvent> filter({
    String query = '',
    AgendaFilterStatus status = AgendaFilterStatus.all,
  }) {
    final now = DateTime.now();
    final cleanQuery = query.trim().toLowerCase();

    return _events.where((e) {
      // 关键字搜索（标题、地点、描述、清单）
      if (cleanQuery.isNotEmpty) {
        final inTitle = e.title.toLowerCase().contains(cleanQuery);
        final inLocation = e.location.toLowerCase().contains(cleanQuery);
        final inDesc = e.description.toLowerCase().contains(cleanQuery);
        final inChecklist =
            e.checklist.any((item) => item.toLowerCase().contains(cleanQuery));
        if (!inTitle && !inLocation && !inDesc && !inChecklist) {
          return false;
        }
      }

      // 状态过滤
      switch (status) {
        case AgendaFilterStatus.all:
          return true;
        case AgendaFilterStatus.upcoming:
          return e.endTime.isAfter(now);
        case AgendaFilterStatus.past:
          return e.endTime.isBefore(now);
        case AgendaFilterStatus.synced:
          return e.syncedToSystemCalendar;
        case AgendaFilterStatus.unsynced:
          return !e.syncedToSystemCalendar;
      }
    }).toList();
  }

  /// 将所有日程打包导出为单个标准 iCalendar (.ics) 文本
  @override
  String exportAllToIcs() {
    String formatIcsDate(DateTime dt) {
      final utc = dt.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${utc.year}${two(utc.month)}${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
    }

    final buffer = StringBuffer()
      ..writeln('BEGIN:VCALENDAR')
      ..writeln('VERSION:2.0')
      ..writeln('PRODID:-//Anno2Agenda//On-Device AI Agenda Extractor//CN')
      ..writeln('CALSCALE:GREGORIAN')
      ..writeln('METHOD:PUBLISH');

    for (final ev in _events) {
      final cleanDesc = [
        if (ev.description.isNotEmpty) ev.description,
        if (ev.checklist.isNotEmpty) '待办事项：${ev.checklist.join("；")}',
        '提取自通知原文：${ev.sourceText.replaceAll("\n", " ")}',
      ].join('\\n');

      buffer
        ..writeln('BEGIN:VEVENT')
        ..writeln('UID:${ev.id}@anno2agenda.local')
        ..writeln('DTSTAMP:${formatIcsDate(DateTime.now())}')
        ..writeln('DTSTART:${formatIcsDate(ev.startTime)}')
        ..writeln('DTEND:${formatIcsDate(ev.endTime)}')
        ..writeln('SUMMARY:${ev.title}')
        ..writeln('LOCATION:${ev.location}')
        ..writeln('DESCRIPTION:$cleanDesc')
        ..writeln('BEGIN:VALARM')
        ..writeln('TRIGGER:-PT${ev.reminderMinutes}M')
        ..writeln('ACTION:DISPLAY')
        ..writeln('DESCRIPTION:Reminder')
        ..writeln('END:VALARM')
        ..writeln('END:VEVENT');
    }

    buffer.writeln('END:VCALENDAR');
    return buffer.toString();
  }

  void _sortEvents() {
    _events.sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  void _notify() {
    eventsNotifier.value = List.unmodifiable(_events);
  }

  Future<void> _persist() async {
    try {
      final file = _storageFile;
      if (file != null) {
        await file.writeAsString(AgendaEvent.encodeList(_events));
      }
    } catch (e) {
      debugPrint('[AgendaRepository] 持久化保存失败: $e');
    }
  }
}
