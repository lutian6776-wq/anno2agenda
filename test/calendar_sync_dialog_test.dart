import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/models/agenda_event.dart';
import 'package:anno2agenda/pages/my_agenda_page.dart';
import 'package:anno2agenda/repositories/agenda_repository.dart';
import 'package:anno2agenda/widgets/calendar_sync_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await AgendaRepository.instance.clearAll();
  });

  testWidgets('CalendarSyncPanel renders as mobile bottom sheet with drag handle',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => CalendarSyncPanel.showBottomSheet(context),
              child: const Text('打开移动端抽屉'),
            ),
          ),
        ),
      ),
    );

    // 点击打开底部抽屉
    await tester.tap(find.text('打开移动端抽屉'));
    await tester.pumpAndSettle();

    // 1. 验证为 BottomSheet 抽屉形态
    expect(find.byType(BottomSheet), findsOneWidget);

    // 2. 验证标题存在，无技术细节
    expect(find.text('系统日历双向同步中心'), findsOneWidget);
    expect(find.textContaining('原生直连'), findsNothing);
    expect(find.textContaining('CalendarProvider'), findsNothing);

    // 3. 验证三联卡片与状态指示条
    expect(find.text('本地日程'), findsOneWidget);
    expect(find.text('所有日程已是最新'), findsOneWidget);

    // 4. 点击关闭
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('CalendarSyncPanel status indicator shows pending count when unsynced',
      (tester) async {
    await AgendaRepository.instance.addEvent(
      AgendaEvent(
        id: 'unsynced_1',
        title: '待同步会议',
        startTime: DateTime.now().add(const Duration(hours: 2)),
        endTime: DateTime.now().add(const Duration(hours: 3)),
        sourceText: '',
        syncedToSystemCalendar: false,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => CalendarSyncPanel.showBottomSheet(context),
              child: const Text('打开移动端抽屉'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开移动端抽屉'));
    await tester.pumpAndSettle();

    expect(find.text('有 1 条日程待同步'), findsOneWidget);
    expect(find.text('所有日程已是最新'), findsNothing);
    expect(find.textContaining('无变动项 (已有'), findsNothing);
  });

  testWidgets(
      'MyAgendaPage desktop layout pushes right slide drawer and narrows main content without overlapping',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MyAgendaPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初始状态：抽屉未展开
    expect(find.byType(CalendarSyncPanel), findsNothing);

    // 获取左侧日历表的初始宽度 (应为 370.0)
    final leftBoxFinder = find.ancestor(
      of: find.byType(SingleChildScrollView).first,
      matching: find.byType(SizedBox),
    ).first;
    final initialLeftWidth =
        tester.renderObject<RenderBox>(leftBoxFinder).size.width;
    expect(initialLeftWidth, closeTo(370.0, 5.0));

    // 获取顶部同步按钮
    final syncBtnFinder = find.byTooltip('系统日历双向同步中心');
    expect(syncBtnFinder, findsOneWidget);

    // 触发桌面端右侧抽屉展开
    await tester.tap(syncBtnFinder);
    await tester.pumpAndSettle();

    // 验证抽屉出现并呈现 CalendarSyncPanel
    expect(find.byType(CalendarSyncPanel), findsOneWidget);
    expect(find.text('系统日历双向同步中心'), findsOneWidget);

    // 核心断言：抽屉推出时，日历表绝对不让位，其宽度与初始宽度严格保持一致！
    final drawerOpenLeftWidth =
        tester.renderObject<RenderBox>(leftBoxFinder).size.width;
    expect(drawerOpenLeftWidth, equals(initialLeftWidth));

    // 再次点击抽屉内的“×”关闭按钮，平滑收回抽屉
    final closeBtnFinder = find.descendant(
      of: find.byType(CalendarSyncPanel),
      matching: find.byIcon(Icons.close),
    );
    expect(closeBtnFinder, findsOneWidget);
    await tester.tap(closeBtnFinder);
    await tester.pumpAndSettle();

    // 验证抽屉已收回，日历表宽度依然不变
    expect(find.byType(CalendarSyncPanel), findsNothing);
    final drawerClosedLeftWidth =
        tester.renderObject<RenderBox>(leftBoxFinder).size.width;
    expect(drawerClosedLeftWidth, equals(initialLeftWidth));

    await tester.binding.setSurfaceSize(null);
  });
}
