import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/models/agenda_event.dart';
import 'package:anno2agenda/repositories/agenda_repository.dart';
import 'package:anno2agenda/services/agenda_write_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AgendaRepository repo;
  late AgendaWriteService service;

  setUp(() async {
    repo = AgendaRepository.instance;
    await repo.clearAll();
    service = AgendaWriteService(repo: repo);
  });

  tearDown(() async {
    await repo.clearAll();
  });

  test('AgendaWriteService saves event locally and returns detailed result', () async {
    final event = AgendaEvent(
      id: 'test_ev_1',
      title: '高数期中考试',
      startTime: DateTime(2026, 11, 1, 9, 0),
      endTime: DateTime(2026, 11, 1, 11, 0),
      location: '一教101',
      sourceText: '11月1日上午9点在一教101进行高数期中考试',
      sourceType: 'manual',
    );

    final result = await service.writeEvent(event, writeToSystemCalendar: false);

    expect(result.success, isTrue);
    expect(result.persisted, isTrue);
    expect(result.eventId, 'test_ev_1');
    expect(repo.allEvents.length, 1);
    expect(repo.allEvents.first.title, '高数期中考试');
  });

  test('AgendaWriteService deduplicates by exact ID', () async {
    final event1 = AgendaEvent(
      id: 'dup_id_100',
      title: '软件工程例会',
      startTime: DateTime(2026, 11, 2, 14, 0),
      endTime: DateTime(2026, 11, 2, 15, 0),
      location: '计电楼304',
      sourceText: '周一下午2点计电楼304软工例会',
      syncedToSystemCalendar: true,
      systemCalendarEventId: 'sys_cal_999',
    );

    // 先存入一条已同步的日程
    await service.writeEvent(event1, writeToSystemCalendar: false);
    expect(repo.allEvents.length, 1);

    // 再次尝试写入同一 ID 但更新了描述的日程
    final event2 = AgendaEvent(
      id: 'dup_id_100',
      title: '软件工程例会 (更新)',
      startTime: DateTime(2026, 11, 2, 14, 0),
      endTime: DateTime(2026, 11, 2, 15, 0),
      location: '计电楼304',
      description: '请带上设计文档',
      sourceText: '周一下午2点计电楼304软工例会，请带上设计文档',
      syncedToSystemCalendar: false,
    );

    final result = await service.writeEvent(event2, writeToSystemCalendar: true);

    expect(result.success, isTrue);
    expect(result.message, contains('避免重复写入'));
    expect(repo.allEvents.length, 1, reason: '去重后应只有 1 条记录');
    expect(repo.allEvents.first.description, '请带上设计文档');
    expect(repo.allEvents.first.syncedToSystemCalendar, isTrue);
    expect(repo.allEvents.first.systemCalendarEventId, 'sys_cal_999');
  });

  test('AgendaWriteService deduplicates by semantic (title + time + location)', () async {
    final event1 = AgendaEvent(
      id: 'first_random_id',
      title: '算法导论研讨会',
      startTime: DateTime(2026, 11, 3, 19, 0),
      endTime: DateTime(2026, 11, 3, 20, 30),
      location: '腾讯会议：123-456-789',
      sourceText: '11月3日晚7点腾讯会议：123-456-789举行算法导论研讨会',
      syncedToSystemCalendar: true,
      systemCalendarEventId: 'sys_cal_777',
    );

    await repo.addEvent(event1);

    // 另一个不同 ID 但核心三要素完全一致的日程
    final event2 = AgendaEvent(
      id: 'second_different_id',
      title: '算法导论研讨会',
      startTime: DateTime(2026, 11, 3, 19, 0),
      endTime: DateTime(2026, 11, 3, 20, 30),
      location: '腾讯会议：123-456-789',
      sourceText: '算法导论研讨会 通知',
    );

    final result = await service.writeEvent(event2, writeToSystemCalendar: true);

    expect(result.success, isTrue);
    expect(repo.allEvents.length, 1, reason: '三要素相同应命中去重');
    expect(repo.allEvents.first.id, 'first_random_id');
    expect(repo.allEvents.first.syncedToSystemCalendar, isTrue);
  });

  test('AgendaWriteService syncOverlayWrittenEvents integrates overlay writes', () async {
    final overlayEvents = [
      AgendaEvent(
        id: 'overlay_ev_1',
        title: '大学英语六级宣讲',
        startTime: DateTime(2026, 11, 5, 10, 0),
        endTime: DateTime(2026, 11, 5, 11, 30),
        location: '大礼堂',
        sourceText: '大礼堂六级宣讲',
        sourceType: 'floating',
        syncedToSystemCalendar: true,
        systemCalendarEventId: 'overlay_sys_101',
      ),
      AgendaEvent(
        id: 'overlay_ev_2',
        title: '创新创业项目答辩',
        startTime: DateTime(2026, 11, 6, 15, 0),
        endTime: DateTime(2026, 11, 6, 17, 0),
        location: '创业大厦201',
        sourceText: '创业大厦项目答辩',
        sourceType: 'floating',
        syncedToSystemCalendar: true,
        systemCalendarEventId: 'overlay_sys_102',
      ),
    ];

    final batchResult = await service.syncOverlayWrittenEvents(overlayEvents);

    expect(batchResult.isAllSuccess, isTrue);
    expect(batchResult.successCount, 2);
    expect(repo.allEvents.length, 2);
    expect(repo.allEvents.any((e) => e.title == '大学英语六级宣讲'), isTrue);
    expect(repo.allEvents.any((e) => e.title == '创新创业项目答辩'), isTrue);
    expect(repo.allEvents.first.syncedToSystemCalendar, isTrue);
  });
}
