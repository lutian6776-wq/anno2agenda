import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';
import 'package:anno2agenda/models/agenda_event.dart';

void main() {
  setUp(() {
    AIExtractorService.currentEngineMode = AIEngineMode.builtInRuleEngine;
  });

  test('AIExtractorService correctly parses cross-day event with overnight hours',
      () async {
    const text = '实验室通宵测试安排通知：10月25日 22:00 至次日 02:00 在计算机中心机房进行压力测试，请提前备份数据。';
    final result = await AIExtractorService.extractFromText(rawText: text);

    expect(result.events.isNotEmpty, isTrue);
    final event = result.events.first;
    expect(event.startTime.month, 10);
    expect(event.startTime.day, 25);
    expect(event.startTime.hour, 22);

    expect(event.endTime.month, 10);
    expect(event.endTime.day, 26);
    expect(event.endTime.hour, 2);
    expect(event.endTime.isAfter(event.startTime), isTrue);
  });

  test('AIExtractorService correctly parses cross-day event with date range',
      () async {
    const text = '关于举办创客挑战赛的通知：10月25日-10月27日在学生活动中心举行，请各队伍按时报到。';
    final result = await AIExtractorService.extractFromText(rawText: text);

    expect(result.events.isNotEmpty, isTrue);
    final event = result.events.first;
    expect(event.startTime.month, 10);
    expect(event.startTime.day, 25);

    expect(event.endTime.month, 10);
    expect(event.endTime.day, 27);
    expect(event.endTime.isAfter(event.startTime), isTrue);
  });
}
