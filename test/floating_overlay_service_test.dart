import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/models/agenda_event.dart';
import 'package:anno2agenda/repositories/agenda_repository.dart';
import 'package:anno2agenda/services/floating_overlay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AgendaRepository repo;
  late FloatingOverlayService overlayService;

  setUp(() async {
    repo = AgendaRepository.instance;
    await repo.clearAll();
    overlayService = FloatingOverlayService.instance;
  });

  tearDown(() async {
    await repo.clearAll();
  });

  test('FloatingOverlayService isRunningNotifier updates correctly', () {
    expect(overlayService.isRunningNotifier.value, isFalse);

    overlayService.isRunningNotifier.value = true;
    expect(overlayService.isRunning, isTrue);

    overlayService.isRunningNotifier.value = false;
    expect(overlayService.isRunning, isFalse);
  });

  test('FloatingOverlayService handles overlay extracted events dispatching', () {
    List<AgendaEvent>? receivedEvents;
    String? receivedEngine;

    overlayService.onOverlayExtractedEvents = (events, engine) {
      receivedEvents = events;
      receivedEngine = engine;
    };

    final testEvents = [
      AgendaEvent(
        id: 'ext_1',
        title: '测试提取日程',
        startTime: DateTime(2026, 11, 10, 8, 0),
        endTime: DateTime(2026, 11, 10, 9, 0),
        sourceText: '测试',
      )
    ];

    overlayService.dispatchOverlayExtractedEvents(testEvents, '端侧测试引擎');

    expect(receivedEvents, isNotNull);
    expect(receivedEvents!.length, 1);
    expect(receivedEvents!.first.title, '测试提取日程');
    expect(receivedEngine, '端侧测试引擎');
  });

  test('FloatingOverlayService handleOverlayWrittenEvents persists events into AgendaRepository', () async {
    final writtenEvent = AgendaEvent(
      id: 'written_by_overlay_1',
      title: '教务处评教提醒',
      startTime: DateTime(2026, 11, 15, 12, 0),
      endTime: DateTime(2026, 11, 15, 13, 0),
      location: '教务系统网站',
      sourceText: '评教通知原文',
      sourceType: 'floating',
      syncedToSystemCalendar: true,
      systemCalendarEventId: 'sys_cal_4001',
    );

    final res = await overlayService.handleOverlayWrittenEvents([writtenEvent]);

    expect(res.isAllSuccess, isTrue);
    expect(repo.allEvents.length, 1);
    expect(repo.allEvents.first.id, 'written_by_overlay_1');
    expect(repo.allEvents.first.title, '教务处评教提醒');
    expect(repo.allEvents.first.syncedToSystemCalendar, isTrue);
    expect(repo.allEvents.first.systemCalendarEventId, 'sys_cal_4001');
  });
}
