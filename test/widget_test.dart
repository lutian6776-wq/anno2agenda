import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/main.dart';
import 'package:anno2agenda/pages/my_agenda_page.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';
import 'package:anno2agenda/services/chinese_calendar_helper.dart';

void main() {
  test('AIExtractorService extracts multiple schedule items from campus notice', () async {
    const sampleNotice = '【AI与开源创新大赛】1. 明天下午14:30在综合楼302报告厅举行赛题宣讲会，请携带学生证签到；'
        '2. 本周日晚上20:00在腾讯会议：884-291-003 开展线上培训。';

    final logs = <String>[];
    final result = await AIExtractorService.extractFromText(
      rawText: sampleNotice,
      mode: AIEngineMode.builtInRuleEngine,
      onProgress: ({stepLog, token, tokenCount}) {
        if (stepLog != null) logs.add(stepLog);
      },
    );

    expect(result.events.length, greaterThanOrEqualTo(2));
    expect(result.events.first.location, contains('综合楼302'));
    expect(result.events.first.checklist, isNotEmpty);
    expect(logs, isNotEmpty);
    expect(logs.any((l) => l.contains('纯端侧中文时空启发式规则引擎')), isTrue);
    expect(logs.any((l) => l.contains('[完成] 规则引擎成功提取')), isTrue);
  });

  testWidgets('Anno2Agenda workbench renders without overflow across window sizes',
      (WidgetTester tester) async {
    for (final size in [
      const Size(390, 844), // Mobile portrait
      const Size(820, 620), // Medium window (previously overflowed around 900px)
      const Size(920, 640), // Narrow desktop window
      const Size(1366, 768), // Wide desktop window
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(const Anno2AgendaApp());
      await tester.pumpAndSettle();
      expect(find.textContaining('知程 Anno2Agenda'), findsOneWidget);
      expect(find.text('AI 提取结构化日程'), findsOneWidget);
    }
    await tester.binding.setSurfaceSize(null);
  });

  test('ChineseCalendarHelper correctly calculates lunar and holiday info', () {
    final oct1 = DateTime(2026, 10, 1);
    final info1 = ChineseCalendarHelper.getInfo(oct1);
    expect(info1.holidayBadge, '休');
    expect(info1.isRest, isTrue);
    expect(info1.lunarText, contains('国庆'));

    final oct10 = DateTime(2026, 10, 10);
    final info10 = ChineseCalendarHelper.getInfo(oct10);
    expect(info10.holidayBadge, '班');
    expect(info10.isRest, isFalse);
    expect(info10.lunarText, '辛亥革命');
  });

  testWidgets('MyAgendaPage renders calendar, span popup button, and FAB',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MyAgendaPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify FAB "今"
    expect(find.text('今'), findsOneWidget);

    // Verify weekdays 一 二 三 四 五 六 日
    for (final day in ['一', '二', '三', '四', '五', '六', '日']) {
      expect(find.text(day), findsWidgets);
    }

    // Verify Span selector button
    expect(find.textContaining('跨度: 月视图'), findsOneWidget);

    // Tap span button to open modal
    await tester.tap(find.textContaining('跨度: 月视图'));
    await tester.pumpAndSettle();

    // Verify modal options and checkboxes
    expect(find.text('选择时间跨度与日历视图'), findsOneWidget);
    expect(find.text('月跨度 (月视图)'), findsOneWidget);
    expect(find.text('周跨度 (周视图)'), findsOneWidget);
    expect(find.text('日跨度 (单日视图)'), findsOneWidget);
    expect(find.text('全部跨度 (列表检索模式)'), findsOneWidget);
    expect(find.text('显示法定节假日与调休标识 (休 / 班)'), findsOneWidget);
    expect(find.text('显示中国传统农历与二十四节气'), findsOneWidget);

    // Scroll until button visible and close modal
    await tester.scrollUntilVisible(
      find.text('确定应用'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('确定应用'));
    await tester.pumpAndSettle();

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('HomeWorkbenchPage bottom bar is preserved and switches to MyAgendaPage',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(const Anno2AgendaApp());
    await tester.pumpAndSettle();

    // Verify original bottom bar destinations are present
    expect(find.text('AI 提取'), findsWidgets);
    expect(find.text('我的日程'), findsWidgets);
    expect(find.text('设置'), findsWidgets);

    // Tap "我的日程" bottom nav destination
    await tester.tap(find.text('我的日程').first);
    await tester.pumpAndSettle();

    // Verify MyAgendaPage is displayed with calendar elements
    expect(find.text('今'), findsOneWidget);
    expect(find.textContaining('跨度: 月视图'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Workbench correctly shows standby model state without misleading ready badge',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 700));
    await tester.pumpWidget(const Anno2AgendaApp());
    await tester.pumpAndSettle();

    // Verify misleading "🟢 本机大模型就绪" does NOT exist when model is not actually loaded into RAM
    expect(find.textContaining('🟢 本机大模型就绪'), findsNothing);

    // Verify engine status badge exists
    expect(find.textContaining('引擎:'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });
}
