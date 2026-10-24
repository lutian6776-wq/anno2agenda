import 'dart:convert';

class AgendaEvent {
  final String id;
  String title;
  DateTime startTime;
  DateTime endTime;
  String location;
  String description;
  final String sourceText;
  final String sourceType; // 'manual', 'process_text', 'share', 'floating', 'lan_sync'
  int reminderMinutes;
  List<String> checklist;
  final double confidence;
  bool syncedToSystemCalendar;
  final String deviceOrigin; // 'android' or 'windows'
  String? systemCalendarEventId;

  AgendaEvent({
    required this.id,
    required this.title,
    required this.startTime,
    required this.endTime,
    this.location = '',
    this.description = '',
    required this.sourceText,
    this.sourceType = 'manual',
    this.reminderMinutes = 30,
    List<String>? checklist,
    this.confidence = 0.92,
    this.syncedToSystemCalendar = false,
    this.deviceOrigin = 'local',
    this.systemCalendarEventId,
  }) : checklist = checklist ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'location': location,
        'description': description,
        'sourceText': sourceText,
        'sourceType': sourceType,
        'reminderMinutes': reminderMinutes,
        'checklist': checklist,
        'confidence': confidence,
        'syncedToSystemCalendar': syncedToSystemCalendar,
        'deviceOrigin': deviceOrigin,
        'systemCalendarEventId': systemCalendarEventId,
      };

  /// 转换为与 Android/原生 MethodChannel 通信的完整协议 Map
  Map<String, dynamic> toChannelMap() => {
        'id': id,
        'title': title,
        'startTime': startTime.toIso8601String(),
        'startMillis': startTime.millisecondsSinceEpoch,
        'endTime': endTime.toIso8601String(),
        'endMillis': endTime.millisecondsSinceEpoch,
        'location': location,
        'description': description,
        'sourceText': sourceText,
        'sourceType': sourceType,
        'reminderMinutes': reminderMinutes,
        'checklist': checklist,
        'confidence': confidence,
        'syncedToSystemCalendar': syncedToSystemCalendar,
        'deviceOrigin': deviceOrigin,
        'systemCalendarEventId': systemCalendarEventId,
      };

  factory AgendaEvent.fromJson(Map<String, dynamic> json) {
    DateTime start;
    final parsedStart = DateTime.tryParse(json['startTime']?.toString() ?? '');
    if (parsedStart != null) {
      start = parsedStart;
    } else if (json['startMillis'] != null) {
      final millis = (json['startMillis'] is num)
          ? (json['startMillis'] as num).toInt()
          : int.tryParse(json['startMillis'].toString());
      start = millis != null
          ? DateTime.fromMillisecondsSinceEpoch(millis)
          : DateTime.now().add(const Duration(hours: 1));
    } else {
      start = DateTime.now().add(const Duration(hours: 1));
    }

    DateTime end;
    final parsedEnd = DateTime.tryParse(json['endTime']?.toString() ?? '');
    if (parsedEnd != null) {
      end = parsedEnd;
    } else if (json['endMillis'] != null) {
      final millis = (json['endMillis'] is num)
          ? (json['endMillis'] as num).toInt()
          : int.tryParse(json['endMillis'].toString());
      end = millis != null
          ? DateTime.fromMillisecondsSinceEpoch(millis)
          : start.add(const Duration(hours: 1));
    } else {
      end = start.add(const Duration(hours: 1));
    }

    return AgendaEvent(
      id: json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      title: json['title']?.toString() ?? '未命名日程',
      startTime: start,
      endTime: end,
      location: json['location']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      sourceText: json['sourceText']?.toString() ?? '',
      sourceType: json['sourceType']?.toString() ?? 'manual',
      reminderMinutes: (json['reminderMinutes'] is int)
          ? json['reminderMinutes'] as int
          : int.tryParse(json['reminderMinutes']?.toString() ?? '30') ?? 30,
      checklist: (json['checklist'] is List)
          ? (json['checklist'] as List).map((e) => e.toString()).toList()
          : <String>[],
      confidence: (json['confidence'] is num)
          ? (json['confidence'] as num).toDouble()
          : 0.9,
      syncedToSystemCalendar: json['syncedToSystemCalendar'] == true,
      deviceOrigin: json['deviceOrigin']?.toString() ?? 'local',
      systemCalendarEventId: json['systemCalendarEventId']?.toString(),
    );
  }

  AgendaEvent copyWith({
    String? id,
    String? title,
    DateTime? startTime,
    DateTime? endTime,
    String? location,
    String? description,
    String? sourceText,
    String? sourceType,
    int? reminderMinutes,
    List<String>? checklist,
    double? confidence,
    bool? syncedToSystemCalendar,
    String? deviceOrigin,
    String? systemCalendarEventId,
  }) {
    return AgendaEvent(
      id: id ?? this.id,
      title: title ?? this.title,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      location: location ?? this.location,
      description: description ?? this.description,
      sourceText: sourceText ?? this.sourceText,
      sourceType: sourceType ?? this.sourceType,
      reminderMinutes: reminderMinutes ?? this.reminderMinutes,
      checklist: checklist ?? List.from(this.checklist),
      confidence: confidence ?? this.confidence,
      syncedToSystemCalendar:
          syncedToSystemCalendar ?? this.syncedToSystemCalendar,
      deviceOrigin: deviceOrigin ?? this.deviceOrigin,
      systemCalendarEventId:
          systemCalendarEventId ?? this.systemCalendarEventId,
    );
  }

  /// 生成符合 RFC 5545 标准的 .ics 日历文件内容（供 Windows / 跨平台日历导入）
  String toIcsString() {
    String formatIcsDate(DateTime dt) {
      final utc = dt.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${utc.year}${two(utc.month)}${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
    }

    final cleanDesc = [
      if (description.isNotEmpty) description,
      if (checklist.isNotEmpty) '待办事项：${checklist.join("；")}',
      '提取自通知原文：${sourceText.replaceAll('\n', ' ')}',
    ].join('\\n');

    final buffer = StringBuffer()
      ..writeln('BEGIN:VCALENDAR')
      ..writeln('VERSION:2.0')
      ..writeln('PRODID:-//Anno2Agenda//On-Device AI Agenda Extractor//CN')
      ..writeln('CALSCALE:GREGORIAN')
      ..writeln('METHOD:PUBLISH')
      ..writeln('BEGIN:VEVENT')
      ..writeln('UID:$id@anno2agenda.local')
      ..writeln('DTSTAMP:${formatIcsDate(DateTime.now())}')
      ..writeln('DTSTART:${formatIcsDate(startTime)}')
      ..writeln('DTEND:${formatIcsDate(endTime)}')
      ..writeln('SUMMARY:$title')
      ..writeln('LOCATION:$location')
      ..writeln('DESCRIPTION:$cleanDesc')
      ..writeln('BEGIN:VALARM')
      ..writeln('TRIGGER:-PT${reminderMinutes}M')
      ..writeln('ACTION:DISPLAY')
      ..writeln('DESCRIPTION:Reminder')
      ..writeln('END:VALARM')
      ..writeln('END:VEVENT')
      ..writeln('END:VCALENDAR');
    return buffer.toString();
  }

  static String encodeList(List<AgendaEvent> events) =>
      jsonEncode(events.map((e) => e.toJson()).toList());

  static List<AgendaEvent> decodeList(String raw) {
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((item) => AgendaEvent.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
