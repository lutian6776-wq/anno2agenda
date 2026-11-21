import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/models/agenda_event.dart';
import 'package:anno2agenda/repositories/agenda_repository.dart';
import 'package:anno2agenda/pages/settings_page.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';
import 'package:anno2agenda/services/app_settings_service.dart';
import 'package:anno2agenda/services/local_model_manager.dart';

void main() {
  setUp(() {
    AppSettingsService.instance.resetForTest();
    AppSettingsService.instance.skipPersistForTest = true;
  });

  tearDown(() {
    AppSettingsService.instance.resetForTest();
    AIExtractorService.resetCloudStatus();
  });

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

    // 2. Module 2: Engine settings (Cloud Engine above On-Device Engine)
    expect(find.text('云端引擎'), findsWidgets);
    expect(find.text('端侧引擎'), findsWidgets);
    expect(find.text('模型管家'), findsOneWidget);

    // Test clicking "模型管家" row calls onOpenModelCenter and opens bottom sheet
    await tester.ensureVisible(find.text('模型管家'));
    await tester.tap(find.text('模型管家'));
    await tester.pumpAndSettle();
    expect(modelCenterOpened, isTrue);
    expect(find.text('端侧模型管家'), findsOneWidget);

    // Close bottom sheet so subsequent interactions are unobstructed
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('端侧模型管家'), findsNothing);

    expect(find.text('释放内存'), findsOneWidget); // Because engineIndicatorDetail contains "已载入"
    expect(find.text('深度思考模式'), findsNWidgets(2));
    expect(find.text('开启 Thinking 增强，提升复杂日程解析精准度'), findsOneWidget);
    expect(find.text('空闲内存回收'), findsOneWidget);
    expect(find.text('推理路线与兜底策略'), findsOneWidget);

    // 3. Module 3: Advanced settings & Parameters in continuous surface
    final resetBtnCheckFinder = find.text('恢复参数默认值');
    await tester.scrollUntilVisible(
      resetBtnCheckFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('高级设置'), findsWidgets);
    expect(find.text('系统提示词模板'), findsOneWidget);
    expect(find.text('上下文窗口 (Context Size)'), findsOneWidget);
    expect(find.text('思考 Token 上限 (Max Tokens)'), findsOneWidget);
    expect(find.text('采样温度 (Temperature)'), findsOneWidget);
    expect(find.text('核采样阈值 (Top-P)'), findsOneWidget);
    expect(find.text('重复词惩罚 (Repeat Penalty)'), findsOneWidget);
    expect(resetBtnCheckFinder, findsOneWidget);

    // 4. Test clicking "空闲内存回收" to invoke drawer/bottom sheet
    final idleUnloadFinder = find.text('空闲内存回收');
    await tester.scrollUntilVisible(
      idleUnloadFinder,
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(idleUnloadFinder);
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
    final routeFinder = find.text('推理路线与兜底策略');
    await tester.scrollUntilVisible(
      routeFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(routeFinder);
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
    final desktopIdleFinder = find.text('空闲内存回收');
    await tester.scrollUntilVisible(
      desktopIdleFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(desktopIdleFinder);
    await tester.pumpAndSettle();

    // Drawer is open on the right
    expect(find.text('空闲内存回收策略'), findsOneWidget);
    expect(find.byTooltip('关闭面板'), findsOneWidget);

    // Close panel
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();

    expect(find.text('空闲内存回收策略'), findsNothing);

    // Click "模型管家" on desktop
    final desktopModelMgrFinder = find.text('模型管家');
    await tester.scrollUntilVisible(
      desktopModelMgrFinder,
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(desktopModelMgrFinder);
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

  testWidgets('SettingsPage renders Cloud Engine card above On-Device Engine with risk modal, greyed state, service drawer, connection test and think switch',
      (WidgetTester tester) async {
    final prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    AppSettingsService.instance.resetForTest();
    AppSettingsService.instance.skipPersistForTest = true;
    addTearDown(() {
      HttpOverrides.global = prevHttpOverrides;
      AppSettingsService.instance.resetForTest();
      AIExtractorService.resetCloudStatus();
    });

    List<String> serverModels = [
      'qwen-0.8',
      'spark',
      'oss',
      'qwen-3.6',
      'qwen-3.8',
      'qwen-lite',
    ];

    HttpServer? server;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((req) async {
        if (req.uri.path == '/v1/models') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'object': 'list',
            'data': serverModels.map((id) => {'id': id}).toList(),
          }));
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });
    });
    addTearDown(() async {
      await tester.runAsync(() async => server?.close(force: true));
    });

    await tester.binding.setSurfaceSize(const Size(1100, 950));
    addTearDown(() async => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            engineMode: AIEngineMode.hybridAuto,
            onEngineModeChanged: (_) {},
            engineIndicatorDetail: '引擎待命中',
            onPreloadModel: () {},
            onUnloadModel: () {},
            localIps: const ['192.168.1.100'],
            peerIpController: TextEditingController(),
            onStateRefreshed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Verify "云端引擎" section appears above "端侧引擎"
    final cloudHeaderY = tester.getTopLeft(find.text('云端引擎').last).dy;
    final localHeaderY = tester.getTopLeft(find.text('端侧引擎').last).dy;
    expect(cloudHeaderY, lessThan(localHeaderY));

    // Verify rows exist
    expect(find.text('启动云端引擎'), findsOneWidget);
    expect(find.text('服务管家'), findsOneWidget);
    expect(find.text('选择模型'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.byKey(const Key('cloud_think_mode_switch')), findsOneWidget);

    // 2. When disabled, lower rows are greyed out and disabled
    final opacityWidget = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('服务管家'),
        matching: find.byType(Opacity),
      ).first,
    );
    expect(opacityWidget.opacity, lessThan(1.0));

    final testConnBtnBefore = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('测试连接'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(testConnBtnBefore.onPressed, isNull);

    final cloudThinkBefore = tester.widget<Switch>(
      find.byKey(const Key('cloud_think_mode_switch')),
    );
    expect(cloudThinkBefore.onChanged, isNull);

    // Tapping 服务管家 or 选择模型 while disabled must not open drawer
    await tester.tap(find.text('服务管家'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('云端服务管家'), findsNothing);

    await tester.tap(find.text('选择模型'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('模型选择'), findsNothing);

    // 3. First tap on 启动云端引擎 shows risk warning modal
    await tester.tap(find.byKey(const Key('cloud_engine_master_switch')));
    await tester.pumpAndSettle();
    expect(find.text('启用云端引擎风险提示'), findsOneWidget);
    expect(find.text('知晓并开启'), findsOneWidget);

    // Cancel keeps switch off
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(AppSettingsService.instance.enableCloudEngine, isFalse);
    expect(AppSettingsService.instance.cloudRiskAccepted, isFalse);

    // Tap switch again and accept risk
    await tester.tap(find.byKey(const Key('cloud_engine_master_switch')));
    await tester.pumpAndSettle();
    expect(find.text('启用云端引擎风险提示'), findsOneWidget);
    await tester.tap(find.text('知晓并开启'));
    await tester.pumpAndSettle();

    expect(AppSettingsService.instance.enableCloudEngine, isTrue);
    expect(AppSettingsService.instance.cloudRiskAccepted, isTrue);

    // Lower rows are now active
    final opacityEnabled = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('服务管家'),
        matching: find.byType(Opacity),
      ).first,
    );
    expect(opacityEnabled.opacity, equals(1.0));

    // Toggle off and back on: risk modal should NOT show again
    await tester.tap(find.byKey(const Key('cloud_engine_master_switch')));
    await tester.pumpAndSettle();
    expect(AppSettingsService.instance.enableCloudEngine, isFalse);

    await tester.tap(find.byKey(const Key('cloud_engine_master_switch')));
    await tester.pumpAndSettle();
    expect(find.text('启用云端引擎风险提示'), findsNothing);
    expect(AppSettingsService.instance.enableCloudEngine, isTrue);

    // 4. Open 服务管家 drawer (desktop right slide-out drawer at 1100px width)
    await tester.tap(find.text('服务管家'));
    await tester.pumpAndSettle();
    expect(find.text('云端服务管家'), findsOneWidget);
    expect(find.text('保存并测试'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // Test 取消 closes drawer without saving
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('云端服务管家'), findsNothing);

    // Re-open 服务管家, fill API URL & Key, tap 保存并测试 -> auto fetches models & goes to Step 2
    await tester.tap(find.text('服务管家'));
    await tester.pumpAndSettle();

    final mockUrl = 'http://127.0.0.1:${server!.port}/v1';
    await tester.enterText(
      find.byKey(const Key('cloud_api_url_field')),
      mockUrl,
    );
    await tester.enterText(
      find.byKey(const Key('cloud_api_key_field')),
      'sk-ui-test-key',
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('保存并测试'));
    await tester.tap(find.text('保存并测试'));
    await tester.pump();
    for (var i = 0; i < 80; i++) {
      if (AIExtractorService.cloudConnectionState !=
          CloudConnectionState.testing) {
        break;
      }
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Step 2: multi-select favorite models from dropdown
    expect(find.text('收藏常用模型（可多选）'), findsOneWidget);
    expect(find.byKey(const Key('cloud_favorite_models_dropdown')), findsOneWidget);

    await tester.tap(find.byKey(const Key('cloud_favorite_models_dropdown')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('dropdown_fav_item_qwen-0.8')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dropdown_fav_item_spark')));
    await tester.pumpAndSettle();

    expect(AppSettingsService.instance.favoriteCloudModels,
        ['qwen-0.8', 'spark']);

    await tester.ensureVisible(find.text('完成'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('云端服务管家'), findsNothing);
    expect(AppSettingsService.instance.cloudApiUrl, mockUrl);
    expect(AppSettingsService.instance.cloudApiKey, 'sk-ui-test-key');
    expect(
      AIExtractorService.cloudConnectionState,
      CloudConnectionState.connected,
    );
    expect(find.text('引擎已就绪'), findsOneWidget);

    // 5. Open 选择模型 drawer (matches sketch: 拉取模型列表 + 收藏 + 全部)
    await tester.tap(find.text('选择模型'));
    await tester.pumpAndSettle();
    expect(find.text('模型选择'), findsOneWidget);
    expect(find.byKey(const Key('fetch_cloud_models_button')), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);

    // Toggle '+' on 'oss' in 全部 -> adds to favorites and turns icon into '-'
    expect(
      find.descendant(
        of: find.byKey(const Key('all_fav_toggle_oss')),
        matching: find.byIcon(Icons.add_rounded),
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const Key('all_fav_toggle_oss')));
    await tester.tap(find.byKey(const Key('all_fav_toggle_oss')));
    await tester.pumpAndSettle();

    expect(AppSettingsService.instance.favoriteCloudModels,
        ['qwen-0.8', 'spark', 'oss']);
    expect(
      find.descendant(
        of: find.byKey(const Key('all_fav_toggle_oss')),
        matching: find.byIcon(Icons.remove_rounded),
      ),
      findsOneWidget,
    );

    // Tap '-' on 'oss' -> removes from favorites and turns back to '+'
    await tester.tap(find.byKey(const Key('all_fav_toggle_oss')));
    await tester.pumpAndSettle();
    expect(AppSettingsService.instance.favoriteCloudModels,
        ['qwen-0.8', 'spark']);
    expect(
      find.descendant(
        of: find.byKey(const Key('all_fav_toggle_oss')),
        matching: find.byIcon(Icons.add_rounded),
      ),
      findsOneWidget,
    );

    // Tap blank area of 'qwen-3.6' in 全部 to select directly
    await tester.ensureVisible(find.byKey(const Key('all_select_qwen-3.6')));
    await tester.tap(find.byKey(const Key('all_select_qwen-3.6')));
    await tester.pumpAndSettle();
    expect(AppSettingsService.instance.cloudModelName, 'qwen-3.6');

    // Tap 'spark' in 收藏 to select
    await tester.ensureVisible(find.byKey(const Key('fav_select_spark')));
    await tester.tap(find.byKey(const Key('fav_select_spark')));
    await tester.pumpAndSettle();
    expect(AppSettingsService.instance.cloudModelName, 'spark');

    // Simulate updated server model list where 'spark' is removed
    serverModels = ['qwen-0.8', 'qwen-3.6', 'qwen-lite'];
    await tester.ensureVisible(find.byKey(const Key('fetch_cloud_models_button')));
    await tester.tap(find.byKey(const Key('fetch_cloud_models_button')));
    await tester.pump();
    for (var i = 0; i < 80; i++) {
      if (AIExtractorService.cloudConnectionState !=
          CloudConnectionState.testing) {
        break;
      }
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Unavailable favorite 'spark' is greyed out and cannot be tapped to select
    final sparkOpacity = tester.widget<Opacity>(
      find.descendant(
        of: find.byKey(const Key('fav_model_row_spark')),
        matching: find.byType(Opacity),
      ),
    );
    expect(sparkOpacity.opacity, lessThan(1.0));
    expect(
      tester.widget<InkWell>(find.byKey(const Key('fav_select_spark'))).onTap,
      isNull,
    );

    // Only delete button works on unavailable favorite
    await tester.tap(find.byKey(const Key('fav_delete_spark')));
    await tester.pumpAndSettle();
    expect(AppSettingsService.instance.favoriteCloudModels, ['qwen-0.8']);

    // Select 'qwen-0.8' and close drawer
    await tester.tap(find.byKey(const Key('fav_select_qwen-0.8')));
    await tester.pumpAndSettle();
    expect(AppSettingsService.instance.cloudModelName, 'qwen-0.8');

    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();

    // 6. Direct 测试连接 button on status row
    await tester.tap(find.text('测试连接'));
    await tester.pump();
    for (var i = 0; i < 80; i++) {
      if (AIExtractorService.cloudConnectionState !=
          CloudConnectionState.testing) {
        break;
      }
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(
      AIExtractorService.cloudConnectionState,
      CloudConnectionState.connected,
    );

    // 7. Toggle cloud 深度思考模式 switch
    await tester.tap(find.byKey(const Key('cloud_think_mode_switch')));
    await tester.pumpAndSettle();
    expect(AppSettingsService.instance.enableCloudThinkMode, isTrue);
  });

  testWidgets('SettingsPage on Windows allows switching desktop hardware acceleration backend',
      (WidgetTester tester) async {
    if (!Platform.isWindows) return;

    addTearDown(() async {
      LocalModelManager.resetWindowsRuntimeStateForTest();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.binding.setSurfaceSize(const Size(1100, 950));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            engineMode: AIEngineMode.hybridAuto,
            onEngineModeChanged: (_) {},
            engineIndicatorDetail: '引擎待命中',
            onPreloadModel: () {},
            onUnloadModel: () {},
            localIps: const ['192.168.1.100'],
            peerIpController: TextEditingController(),
            onStateRefreshed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final backendTileFinder = find.text('推理硬件加速');
    await tester.scrollUntilVisible(
      backendTileFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(backendTileFinder, findsOneWidget);
    expect(find.text('自动 (GPU优先)'), findsOneWidget);

    await tester.tap(backendTileFinder);
    await tester.pumpAndSettle();

    expect(find.text('桌面端推理硬件加速'), findsOneWidget);
    expect(find.text('自动模式 (GPU 优先 · CPU 兜底)'), findsOneWidget);
    expect(find.text('纯 CPU 模式 (省显存 · 高兼容)'), findsOneWidget);
    expect(find.text('仅 GPU 模式 (高性能 · 不降级)'), findsOneWidget);

    await tester.tap(find.text('纯 CPU 模式 (省显存 · 高兼容)'));
    await tester.pumpAndSettle();

    expect(LocalModelManager.desktopBackendMode, DesktopBackendMode.cpuOnly);
    expect(
      AppSettingsService.instance.desktopBackendMode,
      DesktopBackendMode.cpuOnly,
    );
    expect(find.text('纯 CPU'), findsOneWidget);
  });
}
