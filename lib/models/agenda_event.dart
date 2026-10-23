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
      };

  factory AgendaEvent.fromJson(Map<String, dynamic> json) {
    final start = DateTime.tryParse(json['startTime']?.toString() ?? '') ??
        DateTime.now().add(const Duration(hours: 1));
    final end = DateTime.tryParse(json['endTime']?.toString() ?? '') ??
        start.add(const Duration(hours: 1));
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
