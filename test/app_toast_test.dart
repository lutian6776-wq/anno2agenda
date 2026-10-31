import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/theme/app_theme.dart';
import 'package:anno2agenda/widgets/app_toast.dart';

void main() {
  testWidgets('AppToast shows, stacks, and auto-dismisses after 2 seconds', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return Column(
                children: [
                  ElevatedButton(
                    onPressed: () => AppToast.show(context, '第一条通知'),
                    child: const Text('Show 1'),
                  ),
                  ElevatedButton(
                    onPressed: () => AppToast.show(context, '第二条通知'),
                    child: const Text('Show 2'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    // 1. 触发第一条通知 (t = 0)
    await tester.tap(find.text('Show 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250)); // 进场动画完毕

    expect(find.text('第一条通知'), findsOneWidget);

    // 间隔 600ms
    await tester.pump(const Duration(milliseconds: 600));

    // 2. 触发第二条通知（从底部弹出往上顶，不必等待第一条）
    await tester.tap(find.text('Show 2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250)); // 第二条进场完毕

    // 两条通知此时同时存在于视图中（堆叠呈现）
    expect(find.text('第一条通知'), findsOneWidget);
    expect(find.text('第二条通知'), findsOneWidget);

    // 3. 第一条通知触发 2 秒计时到期并完成退场动画（2000ms 计时 + 200ms 退场）
    await tester.pump(const Duration(milliseconds: 1000)); // 2s 计时触发 _dismiss
    await tester.pump(const Duration(milliseconds: 250)); // 退场反向动画执行完成
    await tester.pump(); // 刷新节点

    // 第一条通知已到期完全退出，第二条通知仍然存活
    expect(find.text('第一条通知'), findsNothing);
    expect(find.text('第二条通知'), findsOneWidget);

    // 4. 第二条通知也完成 2 秒计时到期与退场
    await tester.pump(const Duration(milliseconds: 800)); // 第二条 2s 到期
    await tester.pump(const Duration(milliseconds: 250)); // 退场反向动画执行完成
    await tester.pump();

    // 第二条通知也完全自动退场
    expect(find.text('第二条通知'), findsNothing);
  });

  testWidgets('AppToast styles with 15px radius, 14sp font size and theme colors', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () => AppToast.show(context, '✅ 提示词保存成功'),
                child: const Text('Show'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // 验证前置 Emoji 被转为视觉图标，文字保持纯净
    expect(find.text('提示词保存成功'), findsOneWidget);

    // 验证文字样式：字号 14sp，颜色为主题 textPrimary
    final textWidget = tester.widget<Text>(find.text('提示词保存成功'));
    expect(textWidget.style?.fontSize, 14.0);
    expect(textWidget.style?.color, AppCustomColors.light.textPrimary);

    // 验证容器圆角为 15px 圆角矩形
    final containerFinder = find.byType(Container);
    bool found15pxBorderRadius = false;
    for (final element in containerFinder.evaluate()) {
      final widget = element.widget as Container;
      final decoration = widget.decoration;
      if (decoration is BoxDecoration && decoration.borderRadius == BorderRadius.circular(15)) {
        found15pxBorderRadius = true;
        // 验证背景色取自主题 surfaceModal
        expect(decoration.color, AppCustomColors.light.surfaceModal);
        // 验证边框色取自主题 borderSubtle
        expect(decoration.border?.top.color, AppCustomColors.light.borderSubtle);
        break;
      }
    }
    expect(found15pxBorderRadius, isTrue);
  });
}
