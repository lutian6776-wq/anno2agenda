import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/pages/settings_page.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';
import 'package:anno2agenda/services/local_model_manager.dart';

void main() {
  testWidgets('SettingsPage renders compact grouped list layout correctly',
      (WidgetTester tester) async {
    final peerIpController = TextEditingController();
    AIEngineMode engineMode = AIEngineMode.hybridAuto;

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
            onOpenModelCenter: () {},
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

    // 2. Module 2: Engine settings (Group Header "端侧引擎", Model Center button, Status, etc.)
    expect(find.text('端侧引擎'), findsWidgets);
    expect(find.text('模型管家'), findsOneWidget);
    expect(find.text('释放内存'), findsOneWidget); // Because engineIndicatorDetail contains "已载入"
    expect(find.text('深度思考模式'), findsOneWidget);
    expect(find.text('开启 Thinking 增强，提升复杂日程解析精准度'), findsOneWidget);
    expect(find.text('空闲内存回收'), findsOneWidget);

    // 3. Module 3: Advanced settings & Parameters in continuous surface
    expect(find.text('高级设置'), findsWidgets);
    expect(find.text('系统提示词模板'), findsOneWidget);
    expect(find.text('上下文窗口 (Context Size)'), findsOneWidget);
    expect(find.text('思考 Token 上限 (Max Tokens)'), findsOneWidget);
    expect(find.text('采样温度 (Temperature)'), findsOneWidget);
    expect(find.text('核采样阈值 (Top-P)'), findsOneWidget);
    expect(find.text('重复词惩罚 (Repeat Penalty)'), findsOneWidget);
    expect(find.text('恢复参数默认值'), findsOneWidget);

    // 4. Test clicking "空闲内存回收" to invoke bottom picker
    await tester.tap(find.text('空闲内存回收'));
    await tester.pumpAndSettle();

    expect(find.text('空闲内存回收策略'), findsOneWidget);
    expect(find.text('1 分钟'), findsOneWidget);
    expect(find.text('3 分钟'), findsOneWidget);
    expect(find.text('5 分钟'), findsWidgets);
    expect(find.text('10 分钟'), findsOneWidget);
    expect(find.text('永不回收'), findsOneWidget);

    // Tap 3 分钟 in the modal to select
    await tester.tap(find.text('3 分钟'));
    await tester.pumpAndSettle();

    expect(LocalModelManager.idleUnloadMinutes, 3);
    expect(find.text('3 分钟'), findsOneWidget);

    // 5. Test clicking "恢复参数默认值" shows secondary confirmation dialog
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
}
