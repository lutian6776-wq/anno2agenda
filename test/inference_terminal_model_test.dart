import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/widgets/inference_terminal.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';

void main() {
  group('InferenceTerminalModel Unit Tests', () {
    test('Initial state is empty and stopped', () {
      final model = InferenceTerminalModel();
      expect(model.isExtracting, isFalse);
      expect(model.processLogs, isEmpty);
      expect(model.streamedTokens, isEmpty);
      expect(model.tokenCount, 0);
      expect(model.elapsedSeconds, 0.0);
      expect(model.hasContent, isFalse);
      expect(model.tokenSpeed, 0.0);
      expect(model.tokenSpeedFormatted, '0.0');
      expect(model.elapsedSecondsFormatted, '0.0');
      expect(model.fullContent, isEmpty);
      model.dispose();
    });

    test('start() resets state and sets isExtracting to true', () {
      final model = InferenceTerminalModel();
      var notificationCount = 0;
      model.addListener(() => notificationCount++);

      model.start(initialLog: '开始推理');
      expect(model.isExtracting, isTrue);
      expect(model.hasContent, isTrue);
      expect(model.processLogs.length, 1);
      expect(model.processLogs.first, contains('开始推理'));
      expect(notificationCount, greaterThanOrEqualTo(1));

      model.dispose();
    });

    test('addLog() and appendToken() updates buffers and notifies listeners', () {
      final model = InferenceTerminalModel();
      model.start();

      model.addLog('步骤 1: 载入模型');
      expect(model.processLogs.length, 1);
      expect(model.processLogs.first, contains('步骤 1: 载入模型'));

      model.appendToken('{"events":', tokenCount: 4);
      expect(model.streamedTokens, '{"events":');
      expect(model.tokenCount, 4);

      model.appendToken(' []}', tokenCount: 6);
      expect(model.streamedTokens, '{"events": []}');
      expect(model.tokenCount, 6);
      expect(model.fullContent, '{"events": []}');

      model.finish(completionLog: '推理结束');
      expect(model.isExtracting, isFalse);
      expect(model.processLogs.length, 2);
      expect(model.processLogs.last, contains('推理结束'));

      model.dispose();
    });

    test('handleProgress() distributes stepLog, token and tokenCount', () {
      final model = InferenceTerminalModel();
      model.start();

      model.handleProgress(stepLog: '正在预热', token: 'Hello', tokenCount: 1);
      expect(model.processLogs.length, 1);
      expect(model.processLogs.first, contains('正在预热'));
      expect(model.streamedTokens, 'Hello');
      expect(model.tokenCount, 1);

      // Using progressCallback
      final cb = model.progressCallback;
      cb(token: ' World', tokenCount: 2);
      expect(model.streamedTokens, 'Hello World');
      expect(model.tokenCount, 2);

      model.dispose();
    });

    test('recordError() records error log and stops extracting', () {
      final model = InferenceTerminalModel();
      model.start();

      model.recordError('连接超时: 127.0.0.1');
      expect(model.isExtracting, isFalse);
      expect(model.processLogs.last, contains('[错误] 连接超时: 127.0.0.1'));

      model.dispose();
    });

    test('clear() resets all properties', () {
      final model = InferenceTerminalModel();
      model.start(initialLog: '测试');
      model.appendToken('token', tokenCount: 1);

      model.clear();
      expect(model.isExtracting, isFalse);
      expect(model.processLogs, isEmpty);
      expect(model.streamedTokens, isEmpty);
      expect(model.tokenCount, 0);
      expect(model.hasContent, isFalse);

      model.dispose();
    });
  });

  group('InferenceTerminal Widget Tests', () {
    testWidgets('Renders empty when model has no content', (tester) async {
      final model = InferenceTerminalModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InferenceTerminal(model: model),
          ),
        ),
      );

      expect(find.text('端侧推理实况'), findsNothing);
      model.dispose();
    });

    testWidgets('Renders and updates when model is populated', (tester) async {
      final model = InferenceTerminalModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InferenceTerminal(model: model),
          ),
        ),
      );

      // Initially invisible
      expect(find.text('运行中'), findsNothing);

      // Start inference
      model.start(initialLog: '模型启动初始化');
      await tester.pump();

      // Title bar & log should be visible
      expect(find.text('运行中'), findsOneWidget);
      expect(find.textContaining('模型启动初始化'), findsOneWidget);

      // Stream tokens
      model.appendToken('{"title": "测试会议"}', tokenCount: 5);
      await tester.pump();

      expect(find.textContaining('{"title": "测试会议"}'), findsOneWidget);

      // Finish inference
      model.finish(completionLog: '完成日程提取');
      await tester.pump();

      expect(find.text('已完成'), findsOneWidget);

      model.dispose();
    });

    testWidgets('Backwards compatibility: supports explicit parameters',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: InferenceTerminal(
              isExtracting: true,
              processLogs: ['[10:00:00.0] 显式参数模式'],
              streamedTokens: '流式输出文本',
              tokenCount: 8,
              elapsedSeconds: 0.5,
            ),
          ),
        ),
      );

      expect(find.text('运行中'), findsOneWidget);
      expect(find.textContaining('显式参数模式'), findsOneWidget);
      expect(find.textContaining('流式输出文本'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.text('tokens'), findsOneWidget);
    });
  });

  group('AIExtractorService terminalModel integration', () {
    test('extractFromText forwards progress to terminalModel', () async {
      final model = InferenceTerminalModel();
      model.start();

      // Calling with builtInRuleEngine mode
      final result = await AIExtractorService.extractFromText(
        rawText: '明天上午10点在302开会讨论项目',
        mode: AIEngineMode.builtInRuleEngine,
        terminalModel: model,
      );

      expect(result.events.length, 1);
      expect(model.processLogs.isNotEmpty, isTrue);
      expect(model.processLogs.any((l) => l.contains('时间锚点') || l.contains('规则引擎')), isTrue);

      model.finish();
      model.dispose();
    });
  });
}
