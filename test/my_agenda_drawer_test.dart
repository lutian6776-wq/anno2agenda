import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/models/agenda_event.dart';
import 'package:anno2agenda/pages/my_agenda_page.dart';
import 'package:anno2agenda/repositories/agenda_repository.dart';

void main() {
  setUp(() async {
    final repo = AgendaRepository.instance;
    await repo.clearAll();
    await repo.addEvent(AgendaEvent(
      id: 'test_my_agenda_ev_1',
      title: '产品发布与技术答疑会',
      startTime: DateTime.now(),
      endTime: DateTime.now().add(const Duration(hours: 2)),
      location: '科技园区会议大厅',
      description: '全员研讨与系统答疑交流',
      checklist: const ['准备演示Demo', '检查投屏设备'],
      sourceText: '通知：产品发布与技术答疑会将于今日召开。',
    ));
  });

  testWidgets(
      'MyAgendaPage on desktop opens right auto-yielding 380dp drawer for details (direct tap) and edit (edit button)',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MyAgendaPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Verify event card is rendered in the list
    expect(find.text('产品发布与技术答疑会'), findsOneWidget);
    expect(find.text('日程详情'), findsNothing);
    expect(find.text('修改日程详情'), findsNothing);

    // 2. Direct tap on event card -> opens "日程详情" in right 380dp drawer
    await tester.tap(find.text('产品发布与技术答疑会'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('日程详情'), findsOneWidget);
    expect(find.text('修改日程'), findsOneWidget);
    expect(find.text('科技园区会议大厅'), findsWidgets);

    // Verify 380dp OverflowBox is present
    final overflowBoxes =
        tester.widgetList<OverflowBox>(find.byType(OverflowBox));
    expect(
        overflowBoxes.any((box) => box.maxWidth == 380 && box.minWidth == 380),
        isTrue);

    // 3. Click "修改日程" in the drawer -> switches seamlessly to edit form
    await tester.tap(find.text('修改日程'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('修改日程详情'), findsOneWidget);
    expect(find.text('返回日程详情'), findsOneWidget);

    // 4. Click "返回日程详情" -> switches back to detail view
    await tester.tap(find.text('返回日程详情'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('日程详情'), findsOneWidget);

    // 5. Close drawer via close icon
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('日程详情'), findsNothing);
    expect(find.text('修改日程详情'), findsNothing);

    // 6. Click edit icon directly on the card -> directly opens edit mode
    final editIconFinder = find.byTooltip('修改日程详情');
    expect(editIconFinder, findsOneWidget);
    await tester.tap(editIconFinder);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('修改日程详情'), findsOneWidget);

    // Tap same card again to fold/collapse
    await tester.tap(find.text('产品发布与技术答疑会').first);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('修改日程详情'), findsNothing);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'MyAgendaPage on mobile (< 880dp) opens BottomSheet for details and switches to edit',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 900));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MyAgendaPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('产品发布与技术答疑会'), findsOneWidget);

    // Direct tap on card in mobile mode -> opens BottomSheet
    await tester.tap(find.text('产品发布与技术答疑会'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('日程详情'), findsOneWidget);
    expect(find.text('修改日程'), findsOneWidget);

    // Tap "修改日程" inside BottomSheet
    await tester.tap(find.text('修改日程'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('修改日程详情'), findsOneWidget);

    // Close bottom sheet via close button
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('修改日程详情'), findsNothing);

    await tester.binding.setSurfaceSize(null);
  });
}
