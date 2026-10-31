import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/models/agenda_event.dart';
import 'package:anno2agenda/pages/ai_extract_page.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';

void main() {
  final sampleEvent = AgendaEvent(
    id: 'test_event_1',
    title: '全栈技术架构峰会',
    startTime: DateTime(2026, 11, 1, 9, 30),
    endTime: DateTime(2026, 11, 3, 18, 0),
    location: '上海国际会议中心',
    description: '年度核心技术规划研讨',
    sourceText: '通知：全栈技术架构峰会将于11月1日至11月3日在上海国际会议中心举行。',
    checklist: const ['准备讲稿PPT', '确认参会名单'],
  );

  Widget createTestWidget({
    required List<AgendaEvent> draftEvents,
    Future<void> Function(AgendaEvent)? onConfirmDraft,
    void Function(AgendaEvent)? onRemoveDraft,
    void Function(AgendaEvent)? onUpdateDraft,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: AIExtractPage(
          inputController: TextEditingController(),
          isExtracting: false,
          draftEvents: draftEvents,
          engineMode: AIEngineMode.hybridAuto,
          selectedModelName: 'test-model',
          llmEndpoint: '',
          lastEngineInfo: '',
          onRunExtraction: ({String sourceType = 'manual'}) async {},
          onConfirmDraft: onConfirmDraft ?? (_) async {},
          onConfirmAllDrafts: ({bool writeSystemCalendar = false}) async {},
          onRemoveDraft: onRemoveDraft ?? (_) {},
          onUpdateDraft: onUpdateDraft,
        ),
      ),
    );
  }

  testWidgets(
      'AIExtractPage on desktop opens right auto-yielding 380dp drawer with OverflowBox on clicking draft item',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));

    await tester.pumpWidget(createTestWidget(draftEvents: [sampleEvent]));
    await tester.pumpAndSettle();

    // Verify compact tile exists with monospace badge
    expect(find.text('全栈技术架构峰会'), findsOneWidget);
    expect(find.text('[ 跨天日程 ]'), findsOneWidget);

    // Initial state: drawer header is not visible
    expect(find.text('修改日程详情'), findsNothing);

    // Click event tile on desktop
    await tester.tap(find.text('全栈技术架构峰会'));
    await tester.pump();
    await tester.pumpAndSettle();

    // Verify 380dp right drawer expanded
    expect(find.text('修改日程详情'), findsOneWidget);
    expect(find.byTooltip('关闭面板'), findsOneWidget);

    // Verify OverflowBox is present in the tree
    final overflowBoxes = tester.widgetList<OverflowBox>(find.byType(OverflowBox));
    expect(overflowBoxes.any((box) => box.maxWidth == 380 && box.minWidth == 380), isTrue);

    // Verify editing inside the drawer
    expect(find.text('上海国际会议中心'), findsWidgets);

    // Close drawer via close button
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('修改日程详情'), findsNothing);

    // Re-open and toggle close by tapping same tile again
    await tester.tap(find.text('全栈技术架构峰会').first);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('修改日程详情'), findsOneWidget);

    await tester.tap(find.text('全栈技术架构峰会').first);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('修改日程详情'), findsNothing);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'AIExtractPage on mobile (< 880dp) opens BottomSheet on clicking draft item',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 900));

    await tester.pumpWidget(createTestWidget(draftEvents: [sampleEvent]));
    await tester.pumpAndSettle();

    // In mobile layout, draft item is rendered with compact tile
    expect(find.text('全栈技术架构峰会'), findsOneWidget);
    expect(find.text('[ 跨天日程 ]'), findsOneWidget);

    // Click event tile in mobile view
    await tester.tap(find.text('全栈技术架构峰会'));
    await tester.pump();
    await tester.pumpAndSettle();

    // BottomSheet header
    expect(find.text('修改日程详情'), findsOneWidget);
    expect(find.byTooltip('关闭面板'), findsOneWidget);

    // Close bottom sheet
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('修改日程详情'), findsNothing);

    await tester.binding.setSurfaceSize(null);
  });
}
