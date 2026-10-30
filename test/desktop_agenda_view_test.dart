import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/pages/my_agenda_page.dart';
import 'package:anno2agenda/models/agenda_event.dart';
import 'package:anno2agenda/repositories/agenda_repository.dart';

void main() {
  setUp(() async {
    final repo = AgendaRepository.instance;
    await repo.clearAll();
    await repo.addEvent(AgendaEvent(
      id: 'desktop_test_ev_1',
      title: '桌面端测试例会',
      startTime: DateTime.now(),
      endTime: DateTime.now().add(const Duration(hours: 1)),
      location: '线上会议室',
      sourceText: '桌面端测试例会通知',
    ));
  });

  testWidgets('MyAgendaPage desktop layout supports draggable split resizing',
      (WidgetTester tester) async {
    // 1024 x 768 isDesktop = true
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MyAgendaPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify desktop layout is present (drag indicator icon is rendered)
    final dragHandleFinder = find.byIcon(Icons.drag_indicator);
    expect(dragHandleFinder, findsOneWidget);

    // Check initial width of the left panel
    // The left panel is a SizedBox before the splitter
    final leftBoxFinder = find.ancestor(
      of: find.byType(SingleChildScrollView).first,
      matching: find.byType(SizedBox),
    ).first;
    final initialRenderBox = tester.renderObject<RenderBox>(leftBoxFinder);
    final initialWidth = initialRenderBox.size.width;
    expect(initialWidth, closeTo(370.0, 5.0));

    // Drag the splitter to the right by 80 pixels using mouse pointer
    await tester.drag(dragHandleFinder, const Offset(80, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    final expandedRenderBox = tester.renderObject<RenderBox>(leftBoxFinder);
    final expandedWidth = expandedRenderBox.size.width;
    expect(expandedWidth > initialWidth, isTrue);

    // Drag to the left by 120 pixels using mouse pointer
    await tester.drag(dragHandleFinder, const Offset(-120, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    final shrunkRenderBox = tester.renderObject<RenderBox>(leftBoxFinder);
    final shrunkWidth = shrunkRenderBox.size.width;
    expect(shrunkWidth < expandedWidth, isTrue);

    // Double tap the splitter to reset to default ratio
    await tester.tap(dragHandleFinder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(dragHandleFinder);
    await tester.pumpAndSettle();

    final resetRenderBox = tester.renderObject<RenderBox>(leftBoxFinder);
    expect(resetRenderBox.size.width, closeTo(initialWidth, 5.0));

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('MyAgendaPage desktop span selector opens popup near anchor instead of bottom drawer',
      (WidgetTester tester) async {
    // 1024 x 768 isDesktop = true
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MyAgendaPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Click span button in desktop mode
    final spanBtnFinder = find.textContaining('跨度: 月视图');
    expect(spanBtnFinder, findsOneWidget);

    await tester.tap(spanBtnFinder);
    await tester.pumpAndSettle();

    // Verify popup appears as a Dialog (not a ModalBottomSheet)
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);

    // Verify popup contents & header buttons without overflow
    expect(find.text('选择时间跨度与日历视图'), findsOneWidget);
    expect(find.text('恢复默认'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.text('周跨度 (周视图)'), findsOneWidget);
    expect(find.text('日跨度 (单日视图)'), findsOneWidget);

    // Click '恢复默认'
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    // Switch span to week view
    await tester.tap(find.text('周跨度 (周视图)'));
    await tester.pumpAndSettle();

    // Close popup
    await tester.tap(find.text('确定应用'));
    await tester.pumpAndSettle();

    // Verify dialog closed and span updated
    expect(find.byType(Dialog), findsNothing);
    expect(find.textContaining('跨度: 周视图'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });
}
