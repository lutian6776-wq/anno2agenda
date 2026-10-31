import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/models/agenda_event.dart';
import 'package:anno2agenda/repositories/agenda_repository.dart';
import 'package:anno2agenda/pages/settings_page.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';
import 'package:anno2agenda/services/local_model_manager.dart';

void main() {
  testWidgets('SettingsPage renders compact grouped list layout correctly with model manager and unified drawers',
      (WidgetTester tester) async {
    final peerIpController = TextEditingController();
    AIEngineMode engineMode = AIEngineMode.hybridAuto;
    bool modelCenterOpened = false;

    await tester.binding.setSurfaceSize(const Size(800, 1200));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            engineMode: engineMode,
            onEngineModeChanged: (mode) => engineMode = mode,
            engineIndicatorDetail: '已载入模型: Qwen-2.5-0.5B (GGUF)',
            onPreloadModel: () {},
            onUnloadModel: () {},
            onOpenModelCenter: () {
              modelCenterOpened = true;
            },
            localIps: const ['192.168.1.100'],
            peerIpController: peerIpController,
            onStateRefreshed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Module 1: Appearance Theme (Single line list tile + Segmented Control)
    expect(find.text('外观主题'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);

    // 2. Module 2: Engine settings (Group Header "端侧引擎", Model Center as first row)
    expect(find.text('端侧引擎'), findsWidgets);
    expect(find.text('模型管家'), findsOneWidget);

    // Test clicking "模型管家" row calls onOpenModelCenter and opens bottom sheet
    await tester.tap(find.text('模型管家'));
    await tester.pumpAndSettle();
    expect(modelCenterOpened, isTrue);
    expect(find.text('端侧模型管家'), findsOneWidget);

    // Close bottom sheet so subsequent interactions are unobstructed
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('端侧模型管家'), findsNothing);

    expect(find.text('释放内存'), findsOneWidget); // Because engineIndicatorDetail contains "已载入"
    expect(find.text('深度思考模式'), findsOneWidget);
    expect(find.text('开启 Thinking 增强，提升复杂日程解析精准度'), findsOneWidget);
    expect(find.text('空闲内存回收'), findsOneWidget);
    expect(find.text('推理路线与兜底策略'), findsOneWidget);

    // 3. Module 3: Advanced settings & Parameters in continuous surface
    expect(find.text('高级设置'), findsWidgets);
    expect(find.text('系统提示词模板'), findsOneWidget);
    expect(find.text('上下文窗口 (Context Size)'), findsOneWidget);
    expect(find.text('思考 Token 上限 (Max Tokens)'), findsOneWidget);
    expect(find.text('采样温度 (Temperature)'), findsOneWidget);
    expect(find.text('核采样阈值 (Top-P)'), findsOneWidget);
    expect(find.text('重复词惩罚 (Repeat Penalty)'), findsOneWidget);
    expect(find.text('恢复参数默认值'), findsOneWidget);

    // 4. Test clicking "空闲内存回收" to invoke drawer/bottom sheet
    await tester.tap(find.text('空闲内存回收'));
    await tester.pumpAndSettle();

    expect(find.text('空闲内存回收策略'), findsOneWidget);
    expect(find.text('1 分钟'), findsOneWidget);
    expect(find.text('3 分钟'), findsOneWidget);
    expect(find.text('5 分钟 (默认推荐)'), findsOneWidget);
    expect(find.text('10 分钟'), findsOneWidget);
    expect(find.text('永不回收 (持续常驻)'), findsOneWidget);

    // Tap 3 分钟 to select (auto applies and closes)
    await tester.tap(find.text('3 分钟'));
    await tester.pumpAndSettle();

    expect(LocalModelManager.idleUnloadMinutes, 3);
    expect(find.text('3 分钟'), findsOneWidget);

    // 5. Test clicking "推理路线与兜底策略" to invoke drawer/bottom sheet
    await tester.tap(find.text('推理路线与兜底策略'));
    await tester.pumpAndSettle();

    expect(find.text('纯端侧极速规则'), findsOneWidget);
    expect(find.text('强制端侧大模型'), findsOneWidget);
    // Select 纯端侧极速规则 (auto applies and closes)
    await tester.tap(find.text('纯端侧极速规则'));
    await tester.pumpAndSettle();
    expect(engineMode, AIEngineMode.builtInRuleEngine);

    // 5.1 Test clicking "打开同步中心" to invoke bottom sheet
    final syncTileFinder = find.text('打开同步中心');
    await tester.scrollUntilVisible(
      syncTileFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(syncTileFinder, findsOneWidget);
    await tester.tap(syncTileFinder);
    await tester.pumpAndSettle();

    expect(find.text('日历同步中心'), findsOneWidget);
    expect(find.text('一键双向智能同步 (推拉对齐)'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('日历同步中心'), findsNothing);

    // 6. Test clicking "恢复参数默认值" shows secondary confirmation dialog
    final resetBtnFinder = find.text('恢复参数默认值');
    await tester.scrollUntilVisible(
      resetBtnFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(resetBtnFinder);
    await tester.pumpAndSettle();

    expect(find.text('确定将上下文大小、采样温度、Top-P 等所有模型采样参数重置为初始默认值吗？'),
        findsOneWidget);
    expect(find.text('确定恢复'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // Cancel pending idle timer by setting to <= 0 and marking activity
    LocalModelManager.idleUnloadMinutes = -1;
    LocalModelManager.markActivity();

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('SettingsPage on desktop opens right slide-out drawer on clicking parameters',
      (WidgetTester tester) async {
    final peerIpController = TextEditingController();

    await tester.binding.setSurfaceSize(const Size(1100, 900));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            engineMode: AIEngineMode.hybridAuto,
            onEngineModeChanged: (_) {},
            engineIndicatorDetail: '已载入模型: Qwen-2.5-0.5B (GGUF)',
            onPreloadModel: () {},
            onUnloadModel: () {},
            onOpenModelCenter: () {},
            localIps: const ['192.168.1.100'],
            peerIpController: peerIpController,
            onStateRefreshed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Click "空闲内存回收" on desktop
    await tester.tap(find.text('空闲内存回收'));
    await tester.pumpAndSettle();

    // Drawer is open on the right
    expect(find.text('空闲内存回收策略'), findsOneWidget);
    expect(find.byTooltip('关闭面板'), findsOneWidget);

    // Close panel
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();

    expect(find.text('空闲内存回收策略'), findsNothing);

    // Click "模型管家" on desktop
    await tester.tap(find.text('模型管家'));
    await tester.pumpAndSettle();

    expect(find.text('端侧模型管家'), findsOneWidget);
    expect(find.text('官方预置端侧模型库'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();

    expect(find.text('端侧模型管家'), findsNothing);

    // Click "打开同步中心" on desktop
    final desktopSyncFinder = find.text('打开同步中心');
    await tester.scrollUntilVisible(
      desktopSyncFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(desktopSyncFinder);
    await tester.pumpAndSettle();

    expect(find.text('日历同步中心'), findsOneWidget);
    expect(find.text('本地日程'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();
    expect(find.text('日历同步中心'), findsNothing);

    // Click Context Size
    final contextSizeFinder = find.text('上下文窗口 (Context Size)');
    await tester.scrollUntilVisible(
      contextSizeFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(contextSizeFinder);
    await tester.pumpAndSettle();

    expect(find.text('上下文窗口大小 (Context Size)'), findsOneWidget);
    expect(find.text('设定数值：'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('SettingsPage calendar sync badge reflects synced vs unsynced state',
      (WidgetTester tester) async {
    await AgendaRepository.instance.clearAll();

    // 1. When no events exist, all is synced -> shows check icon and '已同步'
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            engineMode: AIEngineMode.hybridAuto,
            onEngineModeChanged: (_) {},
            engineIndicatorDetail: '就绪',
            onPreloadModel: () {},
            onUnloadModel: () {},
            localIps: const [],
            peerIpController: TextEditingController(),
            onStateRefreshed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final syncFinder = find.text('打开同步中心');
    await tester.scrollUntilVisible(
      syncFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('已同步'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsWidgets);

    // 2. Add an unsynced event into AgendaRepository
    final now = DateTime.now();
    await AgendaRepository.instance.addEvent(
      AgendaEvent(
        id: 'test_unsynced_1',
        title: '未同步日程事项',
        startTime: now,
        endTime: now.add(const Duration(hours: 1)),
        sourceText: '测试',
        syncedToSystemCalendar: false,
      ),
    );

    // Re-pump SettingsPage to reflect updated repository
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            engineMode: AIEngineMode.hybridAuto,
            onEngineModeChanged: (_) {},
            engineIndicatorDetail: '就绪',
            onPreloadModel: () {},
            onUnloadModel: () {},
            localIps: const [],
            peerIpController: TextEditingController(),
            onStateRefreshed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 未同步'), findsOneWidget);

    // Reset repository after test
    await AgendaRepository.instance.clearAll();
  });
}
