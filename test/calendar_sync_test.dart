import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/models/agenda_event.dart';
import 'package:anno2agenda/repositories/agenda_repository.dart';
import 'package:anno2agenda/services/calendar_sync_service.dart';
import 'package:anno2agenda/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<MethodCall> channelCalls = [];

  setUp(() {
    PlatformBridge.debugForceNativeChannel = true;
    channelCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.anno2agenda/native'),
      (MethodCall methodCall) async {
        channelCalls.add(methodCall);
        switch (methodCall.method) {
          case 'getCalendarEvents':
            return {
              'success': true,
              'events': [
                {
                  'systemCalendarEventId': 'sys_1001',
                  'title': '操作系统研讨课',
                  'description': '科技楼 201',
                  'location': '科技楼 201',
                  'startMillis':
                      DateTime.now().add(const Duration(days: 2)).millisecondsSinceEpoch,
                  'endMillis':
                      DateTime.now().add(const Duration(days: 2, hours: 2)).millisecondsSinceEpoch,
                  'allDay': false,
                  'calendarId': '1',
                },
                {
                  'systemCalendarEventId': 'sys_1002',
                  'title': '高数期中测试',
                  'description': '一号教学楼',
                  'location': '一教 302',
                  'startMillis':
                      DateTime.now().add(const Duration(days: 5)).millisecondsSinceEpoch,
                  'endMillis':
                      DateTime.now().add(const Duration(days: 5, hours: 2)).millisecondsSinceEpoch,
                  'allDay': false,
                  'calendarId': '1',
                },
              ],
            };
          case 'insertCalendarEvent':
            return {
              'success': true,
              'message': '已写入系统日历',
              'eventId': 'sys_inserted_999',
            };
          case 'deleteCalendarEvent':
            return {
              'success': true,
              'message': '已从系统日历删除',
              'rowsAffected': 1,
            };
          case 'updateCalendarEvent':
            return {
              'success': true,
              'message': '已更新系统日历事件',
              'rowsAffected': 1,
            };
          case 'getSystemCalendars':
            return {
              'success': true,
              'calendars': [
                {
                  'id': '1',
                  'accountName': 'local@anno2agenda',
                  'displayName': '知程 AI 日程',
                  'isPrimary': true,
                }
              ],
            };
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    PlatformBridge.debugForceNativeChannel = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.anno2agenda/native'),
      null,
    );
  });

  group('CalendarSyncService Tests', () {
    test('Pull: reads events from system calendar and imports to repository', () async {
      final repo = AgendaRepository.instance;
      await repo.clearAll();

      final service = CalendarSyncService(repo: repo);
      final result = await service.performTwoWaySync(
        options: const CalendarSyncOptions(
          direction: CalendarSyncDirection.pullOnly,
        ),
      );

      expect(result.success, isTrue);
      expect(result.pulledCount, equals(2));
      expect(repo.allEvents.length, equals(2));

      final first = repo.getEventBySystemCalendarId('sys_1001');
      expect(first, isNotNull);
      expect(first!.title, equals('操作系统研讨课'));
      expect(first.syncedToSystemCalendar, isTrue);
      expect(first.sourceType, equals('system_calendar'));
    });

    test('Deduplication: pulling same events again does not create duplicates', () async {
      final repo = AgendaRepository.instance;
      final service = CalendarSyncService(repo: repo);

      final secondResult = await service.performTwoWaySync(
        options: const CalendarSyncOptions(
          direction: CalendarSyncDirection.pullOnly,
        ),
      );

      expect(secondResult.success, isTrue);
      expect(secondResult.pulledCount, equals(0));
      expect(secondResult.unchangedCount, equals(2));
      expect(repo.allEvents.length, equals(2));
    });

    test('Push: pushes unsynced local events to system calendar', () async {
      final repo = AgendaRepository.instance;
      // Add an unsynced local event
      final localEv = AgendaEvent(
        id: 'local_test_1',
        title: '人工智能前沿讲座',
        startTime: DateTime.now().add(const Duration(days: 3)),
        endTime: DateTime.now().add(const Duration(days: 3, hours: 2)),
        sourceText: '人工智能前沿讲座',
        syncedToSystemCalendar: false,
      );
      await repo.addEvent(localEv);

      final service = CalendarSyncService(repo: repo);
      final pushResult = await service.performTwoWaySync(
        options: const CalendarSyncOptions(
          direction: CalendarSyncDirection.pushOnly,
        ),
      );

      expect(pushResult.success, isTrue);
      expect(pushResult.pushedCount, equals(1));

      final updatedLocal = repo.getEventById('local_test_1');
      expect(updatedLocal!.syncedToSystemCalendar, isTrue);
      expect(updatedLocal.systemCalendarEventId, equals('sys_inserted_999'));

      final insertCalls = channelCalls.where((c) => c.method == 'insertCalendarEvent');
      expect(insertCalls.length, equals(1));
    });

    test('Sync Deletion: deletes from both local repo and system calendar', () async {
      final repo = AgendaRepository.instance;
      final syncedEvent = repo.getEventBySystemCalendarId('sys_1001')!;

      final service = CalendarSyncService(repo: repo);
      final delResult = await service.deleteEventWithSync(
        syncedEvent,
        deleteFromSystem: true,
      );

      expect(delResult.success, isTrue);
      expect(repo.getEventById(syncedEvent.id), isNull);
      expect(repo.getEventBySystemCalendarId('sys_1001'), isNull);

      final deleteCalls = channelCalls.where((c) => c.method == 'deleteCalendarEvent');
      expect(deleteCalls.length, equals(1));
      expect(deleteCalls.first.arguments['systemCalendarEventId'], equals('sys_1001'));
    });

    test('Non-system delete: only deletes locally if deleteFromSystem is false', () async {
      final repo = AgendaRepository.instance;
      final syncedEvent = repo.getEventBySystemCalendarId('sys_1002')!;

      final service = CalendarSyncService(repo: repo);
      final delResult = await service.deleteEventWithSync(
        syncedEvent,
        deleteFromSystem: false,
      );

      expect(delResult.success, isTrue);
      expect(repo.getEventById(syncedEvent.id), isNull);

      // Verify no deleteCalendarEvent call was made
      final deleteCalls =
          channelCalls.where((c) => c.method == 'deleteCalendarEvent' &&
              c.arguments['systemCalendarEventId'] == 'sys_1002');
      expect(deleteCalls, isEmpty);
    });

    test('AgendaEvent.fromIcsString correctly parses RFC 5545 format', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Anno2Agenda//Test//CN
BEGIN:VEVENT
UID:sample_ics_test_123@anno2agenda.local
DTSTAMP:20261028T100000Z
DTSTART:20261029T093000Z
DTEND:20261029T110000Z
SUMMARY:线性代数答疑
LOCATION:数学院 405
DESCRIPTION:期中考试前集中答疑
END:VEVENT
END:VCALENDAR''';

      final ev = AgendaEvent.fromIcsString(ics);
      expect(ev, isNotNull);
      expect(ev!.title, equals('线性代数答疑'));
      expect(ev.location, equals('数学院 405'));
      expect(ev.description, contains('期中考试前集中答疑'));
      expect(ev.systemCalendarEventId, equals('sample_ics_test_123'));
    });
  });
}
