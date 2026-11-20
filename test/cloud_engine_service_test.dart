import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';
import 'package:anno2agenda/services/app_settings_service.dart';

void main() {
  setUp(() {
    HttpOverrides.global = null;
  });

  tearDown(() {
    AppSettingsService.instance.resetForTest();
    AIExtractorService.resetCloudStatus();
    AIExtractorService.currentEngineMode = AIEngineMode.hybridAuto;
  });

  test('OpenAI-Compatible URI resolution handles base and full URLs', () {
    expect(
      AIExtractorService.resolveOpenAiChatCompletionsUri('https://api.openai.com/v1')
          .toString(),
      'https://api.openai.com/v1/chat/completions',
    );
    expect(
      AIExtractorService.resolveOpenAiChatCompletionsUri('https://api.deepseek.com/')
          .toString(),
      'https://api.deepseek.com/v1/chat/completions',
    );
    expect(
      AIExtractorService.resolveOpenAiChatCompletionsUri(
              'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions')
          .toString(),
      'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    );
    expect(
      AIExtractorService.resolveOpenAiModelsUri('https://api.openai.com/v1/chat/completions')
          .toString(),
      'https://api.openai.com/v1/models',
    );
    expect(
      AIExtractorService.resolveOpenAiModelsUri('https://api.deepseek.com')
          .toString(),
      'https://api.deepseek.com/v1/models',
    );
  });

  test('getEffectiveCloudModel resolves explicit model or infers from provider URL', () {
    expect(
      AIExtractorService.getEffectiveCloudModel(
          'https://api.deepseek.com/v1', 'deepseek-reasoner'),
      'deepseek-reasoner',
    );
    expect(
      AIExtractorService.getEffectiveCloudModel('https://api.deepseek.com/v1', ''),
      'deepseek-chat',
    );
    expect(
      AIExtractorService.getEffectiveCloudModel(
          'https://dashscope.aliyuncs.com/compatible-mode/v1', ''),
      'qwen-plus',
    );
    expect(
      AIExtractorService.getEffectiveCloudModel('https://api.openai.com/v1', ''),
      'gpt-4o-mini',
    );
  });

  test('testCloudConnection verifies /models, fallback /chat/completions, and 401 error', () async {
    int mode = 0; // 0 = /models 200, 1 = /models 404 + /chat 200, 2 = 401
    String? seenAuth;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((req) async {
      seenAuth = req.headers.value(HttpHeaders.authorizationHeader);
      if (mode == 2) {
        req.response.statusCode = 401;
        req.response.write('{"error":"invalid_api_key"}');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/v1/models') {
        if (mode == 0) {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'object': 'list',
            'data': [
              {'id': 'mock-cloud-model'}
            ]
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
        return;
      }
      if (req.uri.path == '/v1/chat/completions') {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'id': 'chatcmpl-test',
          'model': 'fallback-cloud-model',
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'pong'}
            }
          ]
        }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final baseUrl = 'http://127.0.0.1:${server.port}/v1';

    // 1. /models 200
    final res1 = await AIExtractorService.testCloudConnection(
      apiUrl: baseUrl,
      apiKey: 'sk-mock-123',
    );
    expect(res1.success, isTrue);
    expect(res1.detectedModel, 'mock-cloud-model');
    expect(seenAuth, 'Bearer sk-mock-123');
    expect(AIExtractorService.cloudConnectionState, CloudConnectionState.connected);

    // 2. /models 404 -> fallback /chat/completions
    mode = 1;
    final res2 = await AIExtractorService.testCloudConnection(
      apiUrl: baseUrl,
      apiKey: 'sk-mock-456',
      modelName: 'custom-model',
    );
    expect(res2.success, isTrue);
    expect(AIExtractorService.cloudConnectionState, CloudConnectionState.connected);

    // 3. 401 Unauthorized
    mode = 2;
    final res3 = await AIExtractorService.testCloudConnection(
      apiUrl: baseUrl,
      apiKey: 'sk-bad',
    );
    expect(res3.success, isFalse);
    expect(res3.message, contains('401'));
    expect(AIExtractorService.cloudConnectionState, CloudConnectionState.error);
  });

  test('fetchCloudModels parses DeepSeek/OpenAI /models response and supports root /models fallback', () async {
    bool useRootOnly = false;
    String? seenAccept;
    String? seenAuth;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((req) async {
      seenAccept = req.headers.value(HttpHeaders.acceptHeader);
      seenAuth = req.headers.value(HttpHeaders.authorizationHeader);
      if ((!useRootOnly && req.uri.path == '/v1/models') ||
          (useRootOnly && req.uri.path == '/models')) {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'object': 'list',
          'data': [
            {'id': 'deepseek-chat', 'object': 'model', 'owned_by': 'deepseek'},
            {'id': 'deepseek-reasoner', 'object': 'model', 'owned_by': 'deepseek'},
          ],
        }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final res1 = await AIExtractorService.fetchCloudModels(
      apiUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'sk-ds-123',
    );
    expect(res1.success, isTrue);
    expect(res1.models, ['deepseek-chat', 'deepseek-reasoner']);
    expect(seenAccept, contains('application/json'));
    expect(seenAuth, 'Bearer sk-ds-123');
    expect(AIExtractorService.fetchedCloudModels,
        ['deepseek-chat', 'deepseek-reasoner']);

    // Simulate base domain where /v1/models returns 404 and /models succeeds
    useRootOnly = true;
    final res2 = await AIExtractorService.fetchCloudModels(
      apiUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'sk-ds-root',
    );
    expect(res2.success, isTrue);
    expect(res2.models, ['deepseek-chat', 'deepseek-reasoner']);
  });

  test('extractFromText routes to OpenAI-Compatible SSE stream with reasoning_content and falls back on error', () async {
    bool shouldFail = false;
    Map<String, dynamic>? lastRequestBody;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((req) async {
      if (req.uri.path == '/v1/chat/completions') {
        final rawBody = await utf8.decoder.bind(req).join();
        lastRequestBody = jsonDecode(rawBody) as Map<String, dynamic>;

        if (shouldFail) {
          req.response.statusCode = 500;
          req.response.write('Internal Server Error');
          await req.response.close();
          return;
        }

        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        final payloadJson = jsonEncode({
          'events': [
            {
              'title': '云端提取学术讲座',
              'startTime': '2026-11-20T14:30:00',
              'endTime': '2026-11-20T16:00:00',
              'location': '综合楼302',
              'description': '云端 SSE 推理返回',
              'checklist': ['学生证'],
              'reminderMinutes': 30,
              'confidence': 0.99,
            }
          ]
        });
        req.response.write('data: ${jsonEncode({
          'choices': [
            {
              'delta': {'reasoning_content': '正在分析日期和时间...'}
            }
          ]
        })}\n\n');
        req.response.write('data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': payloadJson}
            }
          ]
        })}\n\n');
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    AIExtractorService.enableCloudEngine = true;
    AIExtractorService.cloudApiUrl = 'http://127.0.0.1:${server.port}/v1';
    AIExtractorService.cloudApiKey = 'sk-stream-key';
    AIExtractorService.cloudModelName = 'deepseek-reasoner';
    AIExtractorService.enableCloudThinkMode = true;

    final streamedTokens = StringBuffer();
    final res = await AIExtractorService.extractFromText(
      rawText: '明天下午14:30在综合楼302举办学术讲座，请携带学生证',
      onProgress: ({stepLog, token, tokenCount}) {
        if (token != null) streamedTokens.write(token);
      },
    );

    expect(res.engineUsed, contains('云端大模型'));
    expect(res.engineUsed, contains('deepseek-reasoner'));
    expect(res.engineUsed, contains('深度思考'));
    expect(res.events.length, 1);
    expect(res.events.first.title, '云端提取学术讲座');
    expect(streamedTokens.toString(), contains('正在分析日期和时间...'));
    expect(lastRequestBody?['model'], 'deepseek-reasoner');
    expect(lastRequestBody?['stream'], isTrue);

    // When cloud errors out in hybridAuto, seamlessly falls back to on-device engine
    shouldFail = true;
    final fallbackRes = await AIExtractorService.extractFromText(
      rawText: '明天下午14:30在综合楼302举办学术讲座',
      llmEndpoint: 'http://127.0.0.1:1/api/generate',
    );
    expect(fallbackRes.events, isNotEmpty);
    expect(fallbackRes.engineUsed, isNot(contains('云端大模型')));
    expect(fallbackRes.engineUsed, contains('规则引擎'));
  });
}
