import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/pages/settings_page.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';

void main() {
  testWidgets('SettingsPage hides explanations initially and expands them on clicking info box button',
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

    // 1. Initial state: Titles should be visible
    expect(find.text('端侧大模型预热与内存常驻设置'), findsOneWidget);
    expect(find.text('空闲内存自动释放'), findsOneWidget);
    expect(find.text('开启深度思考模式 (Think Mode)'), findsOneWidget);
    expect(find.text('推理路线与兜底策略'), findsOneWidget);

    // 2. Initial state: Detailed explanations should NOT be visible (compact UI)
    const idleUnloadText = '无提取任务达到指定时长后，自动解除大模型在 RAM/显存中的常驻';
    const thinkModeText = '大模型输出日程前将完整生成思维链推理过程';
    expect(find.textContaining(idleUnloadText), findsNothing);
    expect(find.textContaining(thinkModeText), findsNothing);

    // 3. Find and tap the info box button for "空闲内存自动释放"
    final idleUnloadInfoFinder = find.byTooltip('查看「空闲内存自动释放」说明');
    expect(idleUnloadInfoFinder, findsOneWidget);

    await tester.tap(idleUnloadInfoFinder);
    await tester.pumpAndSettle();

    // 4. Explanation is now visible!
    expect(find.textContaining(idleUnloadText), findsOneWidget);

    // 5. Tap again to collapse using the collapse tooltip
    final collapseTooltipFinder = find.byTooltip('点击收起说明');
    expect(collapseTooltipFinder, findsOneWidget);

    await tester.tap(collapseTooltipFinder);
    await tester.pumpAndSettle();

    // 6. Explanation is hidden again
    expect(find.textContaining(idleUnloadText), findsNothing);

    // 7. Test Think Mode info box button
    final thinkModeInfoFinder = find.byTooltip('查看「开启深度思考模式 (Think Mode)」说明');
    expect(thinkModeInfoFinder, findsOneWidget);

    await tester.tap(thinkModeInfoFinder);
    await tester.pumpAndSettle();

    expect(find.textContaining('免思考极速模式'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });
}
