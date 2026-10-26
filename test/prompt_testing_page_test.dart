import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/pages/settings_page.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';

void main() {
  test('AIExtractorService replaces {TIME_ANCHOR} correctly in system prompt', () {
    final anchor = DateTime(2026, 10, 24, 14, 30);
    const customTemplate = '任务：提取日程。\n锚点时间：{TIME_ANCHOR}\n输出格式：JSON';
    final result = AIExtractorService.buildSystemPrompt(anchor, customTemplate);
    expect(result, contains('锚点时间：2026-10-24 14:30 (星期六)'));
  });

  test('AIExtractorService.parseAndDiagnoseJson detects valid JSON and flaws', () {
    // 1. 严格合法的标准 JSON
    const cleanJson = '''{
      "events": [
        {
          "title": "测试会议",
          "startTime": "2026-10-25T10:00:00",
          "endTime": "2026-10-25T11:00:00",
          "location": "A101",
          "description": "开会讨论",
          "checklist": ["带笔记本"]
        }
      ]
    }''';
    final diag1 = AIExtractorService.parseAndDiagnoseJson(
      rawJson: cleanJson,
      rawText: '测试通知',
    );
    expect(diag1.events.length, 1);
    expect(diag1.parseError, isNull);

    // 2. 包裹在 markdown 代码块里的 JSON
    const markdownWrapped = '好的，提取结果如下：\n```json\n{"events": [{"title": "宣讲会"}]}\n```';
    final diag2 = AIExtractorService.parseAndDiagnoseJson(
      rawJson: markdownWrapped,
      rawText: '测试通知',
    );
    expect(diag2.events.length, 1);
    expect(diag2.parseError, contains('markdown'));

    // 3. 语法完全错误的文本
    const brokenText = '不是合法的 json 字符';
    final diag3 = AIExtractorService.parseAndDiagnoseJson(
      rawJson: brokenText,
      rawText: '测试通知',
    );
    expect(diag3.events.isEmpty, isTrue);
    expect(diag3.parseError, isNotNull);

    // 4. 违反 GBNF ISO-8601 时间格式的 JSON（容错能提取出事件，但诊断出 GBNF 违规）
    const nonIsoTimeJson = '''{
      "events": [
        {
          "title": "实验课",
          "startTime": "明天下午两点",
          "endTime": "明天下午四点"
        }
      ]
    }''';
    final diag4 = AIExtractorService.parseAndDiagnoseJson(
      rawJson: nonIsoTimeJson,
      rawText: '测试通知',
    );
    expect(diag4.events.length, 1);
    expect(diag4.parseError, contains('GBNF'));
  });

  test('AIExtractorService GBNF grammar and JSON schema definitions are valid', () {
    expect(AIExtractorService.defaultAgendaGbnfGrammar, contains('root ::='));
    expect(AIExtractorService.defaultAgendaGbnfGrammar, contains('iso-datetime ::='));
    expect(AIExtractorService.prefilledAgendaGbnfGrammar, contains('root ::= ws (event-list)?'));
    expect(AIExtractorService.agendaJsonSchema['type'], equals('object'));
    expect(AIExtractorService.agendaJsonSchema['required'], contains('events'));
  });

  testWidgets('SettingsPage renders Advanced Settings card and navigates to PromptTestingPage',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 1200));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            engineMode: AIEngineMode.hybridAuto,
            onEngineModeChanged: (_) {},
            engineIndicatorDetail: '就绪',
            onPreloadModel: () {},
            onUnloadModel: () {},
            onOpenModelCenter: () {},
            localIps: const ['127.0.0.1'],
            peerIpController: TextEditingController(),
            onStateRefreshed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Advanced Settings card exists
    expect(find.text('高级设置'), findsOneWidget);
    expect(find.text('系统提示词修改与测试'), findsOneWidget);

    // Tap entry and navigate to PromptTestingPage
    await tester.tap(find.text('系统提示词修改与测试'));
    await tester.pumpAndSettle();

    // Verify PromptTestingPage elements
    expect(find.text('System Prompt (系统指令模板)'), findsOneWidget);
    expect(find.text('{TIME_ANCHOR} 宏'), findsOneWidget);
    expect(find.text('恢复默认提示词'), findsOneWidget);
    expect(find.text('🚀 运行提示词推理测试'), findsOneWidget);

    // Wait for async local model loader timer
    await tester.pumpAndSettle(const Duration(seconds: 5));

    await tester.binding.setSurfaceSize(null);
  });
}
