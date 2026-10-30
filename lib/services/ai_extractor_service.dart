import 'dart:convert';
import 'dart:io';
import '../models/agenda_event.dart';
import '../models/inference_terminal_model.dart';
import 'local_model_manager.dart';

export '../models/inference_terminal_model.dart';

enum AIEngineMode {
  /// 优先尝试本地大模型 (自动探测/拉起本机模型)，若未就绪则无缝回退至内置端侧规则引擎
  hybridAuto,

  /// 纯内置端侧轻量启发式 + 中文相对时间推算引擎（0 延迟、无需外部模型服务）
  builtInRuleEngine,

  /// 强制连接本地或局域网桌面端 LLM 服务
  localLlmServer,
}

class ExtractionResult {
  final List<AgendaEvent> events;
  final String engineUsed;
  final int elapsedMs;
  final String promptPreview;
  final String? rawResponse;
  final String? jsonParseError;

  ExtractionResult({
    required this.events,
    required this.engineUsed,
    required this.elapsedMs,
    required this.promptPreview,
    this.rawResponse,
    this.jsonParseError,
  });
}

class AIExtractorService {
  /// 全局共享的当前引擎模式（由设置或工作台界面动态切换）
  static AIEngineMode currentEngineMode = AIEngineMode.hybridAuto;

  /// 全局共享的当前偏好模型 ID（如 qwen3.5:2b）
  static String? currentPreferredModel;

  /// 全局共享的当前推理接口地址（供悬浮窗后台调用对齐主程序配置）
  static String currentLlmEndpoint = 'http://127.0.0.1:11434/api/generate';

  /// 是否启用 GBNF (GGML BNF) 强制语法约束（默认开启，在采样层屏蔽一切非规范 Token）
  static bool enableGbnfConstraint = true;

  /// 标准日程提取 GBNF (GGML BNF) 语法规则（约束顶层 {"events":[...]}、字段顺序、类型及 ISO-8601 时间格式）
  static const String defaultAgendaGbnfGrammar = r'''
root ::= ws "{" ws "\"events\"" ws ":" ws "[" ws (event-list)? ws "]" ws "}" ws
event-list ::= event-item (ws "," ws event-item)*
event-item ::= "{" ws
  "\"title\"" ws ":" ws non-empty-string ws "," ws
  "\"startTime\"" ws ":" ws iso-datetime ws "," ws
  "\"endTime\"" ws ":" ws iso-datetime ws "," ws
  "\"location\"" ws ":" ws string ws "," ws
  "\"description\"" ws ":" ws string ws "," ws
  "\"checklist\"" ws ":" ws string-array ws "," ws
  "\"reminderMinutes\"" ws ":" ws integer ws "," ws
  "\"confidence\"" ws ":" ws confidence-num ws
"}"
string-array ::= "[" ws (string (ws "," ws string)*)? ws "]"
iso-datetime ::= "\"" date "T" time "\""
date ::= [0-9]{4} "-" ("0" [1-9] | "1" [0-2]) "-" ("0" [1-9] | [1-2] [0-9] | "3" [0-1])
time ::= ([01] [0-9] | "2" [0-3]) ":" [0-5] [0-9] (":" [0-5] [0-9])?
integer ::= [0] | [1-9] [0-9]{0,3}
confidence-num ::= "0" ("." [0-9]{1,2})? | "1" (".0" | ".00")?
non-empty-string ::= "\"" char+ "\""
string ::= "\"" char* "\""
char ::= [^"\\\x7F\x00-\x1F] | [\\] (["\\bfnrt] | "u" [0-9a-fA-F]{4})
ws ::= | " " | "\n"{1,2} [ \t]{0,16}
''';

  /// 适配 Android 免思考模式预填充 `{"events":[` 后的续写 GBNF 语法规则（严禁重复输出前缀且强制闭合 `]}`）
  static const String prefilledAgendaGbnfGrammar = r'''
root ::= ws (event-list)? ws "]" ws "}" ws
event-list ::= event-item (ws "," ws event-item)*
event-item ::= "{" ws
  "\"title\"" ws ":" ws non-empty-string ws "," ws
  "\"startTime\"" ws ":" ws iso-datetime ws "," ws
  "\"endTime\"" ws ":" ws iso-datetime ws "," ws
  "\"location\"" ws ":" ws string ws "," ws
  "\"description\"" ws ":" ws string ws "," ws
  "\"checklist\"" ws ":" ws string-array ws "," ws
  "\"reminderMinutes\"" ws ":" ws integer ws "," ws
  "\"confidence\"" ws ":" ws confidence-num ws
"}"
string-array ::= "[" ws (string (ws "," ws string)*)? ws "]"
iso-datetime ::= "\"" date "T" time "\""
date ::= [0-9]{4} "-" ("0" [1-9] | "1" [0-2]) "-" ("0" [1-9] | [1-2] [0-9] | "3" [0-1])
time ::= ([01] [0-9] | "2" [0-3]) ":" [0-5] [0-9] (":" [0-5] [0-9])?
integer ::= [0] | [1-9] [0-9]{0,3}
confidence-num ::= "0" ("." [0-9]{1,2})? | "1" (".0" | ".00")?
non-empty-string ::= "\"" char+ "\""
string ::= "\"" char* "\""
char ::= [^"\\\x7F\x00-\x1F] | [\\] (["\\bfnrt] | "u" [0-9a-fA-F]{4})
ws ::= | " " | "\n"{1,2} [ \t]{0,16}
''';

  /// 与 GBNF 对齐的严格 JSON Schema（供 Ollama / llama-server 底层通过 json_schema_to_grammar 编译为 GBNF 采样器）
  static const Map<String, dynamic> agendaJsonSchema = {
    'type': 'object',
    'required': ['events'],
    'additionalProperties': false,
    'properties': {
      'events': {
        'type': 'array',
        'items': {
          'type': 'object',
          'required': [
            'title',
            'startTime',
            'endTime',
            'location',
            'description',
            'checklist',
            'reminderMinutes',
            'confidence',
          ],
          'additionalProperties': false,
          'properties': {
            'title': {'type': 'string', 'minLength': 1},
            'startTime': {
              'type': 'string',
              'pattern':
                  r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$',
            },
            'endTime': {
              'type': 'string',
              'pattern':
                  r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$',
            },
            'location': {'type': 'string'},
            'description': {'type': 'string'},
            'checklist': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'reminderMinutes': {'type': 'integer', 'minimum': 0, 'maximum': 10080},
            'confidence': {'type': 'number', 'minimum': 0.0, 'maximum': 1.0},
          },
        },
      },
    },
  };

  /// 用户自定义配置的 GBNF 语法规则（若为 null 则使用 defaultAgendaGbnfGrammar）
  static String? customGbnfGrammar;

  /// 获取当前生效的 GBNF 语法字符串
  static String get activeGbnfGrammar =>
      (customGbnfGrammar != null && customGbnfGrammar!.trim().isNotEmpty)
          ? customGbnfGrammar!.trim()
          : defaultAgendaGbnfGrammar.trim();

  /// 默认标准系统提示词模板（支持 {TIME_ANCHOR} 宏替换）
  static const String defaultSystemPromptTemplate = '''你是一个运行在端侧设备的高校通知日程提取助手。
【当前系统时间锚点】：{TIME_ANCHOR}
请从用户输入的杂乱群通知、教务文档或视频字幕中提取出所有日程事件，并将相对时间（如“明天”、“本周日”、“下周三晚7点”）严格换算为基于当前时间锚点的 ISO-8601 格式时间。
必须输出如下结构的 JSON 对象：
{
  "events": [
    {
      "title": "事件简短标题",
      "startTime": "YYYY-MM-DDTHH:mm:00",
      "endTime": "YYYY-MM-DDTHH:mm:00",
      "location": "地点或会议号",
      "description": "核心内容摘要",
      "checklist": ["待办或需携带物品1"],
      "reminderMinutes": 30,
      "confidence": 0.95
    }
  ]
}''';

  /// 用户自定义配置的系统提示词（若为 null 则使用 defaultSystemPromptTemplate）
  static String? customSystemPromptTemplate;
  static File? _promptStorageFile;

  /// 初始化提示词持久化存储
  static Future<void> initPromptStorage([String? baseDir]) async {
    try {
      String dir = baseDir ?? '';
      if (dir.isEmpty) {
        dir = Directory.current.path;
      }
      final file = File('$dir/custom_system_prompt.txt');
      _promptStorageFile = file;
      if (await file.exists()) {
        final text = await file.readAsString();
        if (text.trim().isNotEmpty) {
          customSystemPromptTemplate = text;
        }
      }
    } catch (_) {}
  }

  /// 保存自定义系统提示词
  static Future<void> saveCustomPrompt(String? prompt) async {
    customSystemPromptTemplate = prompt?.trim().isEmpty == true ? null : prompt;
    try {
      if (_promptStorageFile != null) {
        if (customSystemPromptTemplate != null) {
          await _promptStorageFile!.writeAsString(customSystemPromptTemplate!);
        } else if (await _promptStorageFile!.exists()) {
          await _promptStorageFile!.delete();
        }
      }
    } catch (_) {}
  }

  /// 恢复默认提示词
  static Future<void> resetDefaultPrompt() async {
    await saveCustomPrompt(null);
  }

  static const List<String> _weekdays = [
    '星期一',
    '星期二',
    '星期三',
    '星期四',
    '星期五',
    '星期六',
    '星期日'
  ];

  /// 构建带当前系统时间锚点与 JSON Schema 约束的端侧小模型 System Prompt
  static String buildSystemPrompt(DateTime anchorTime, [String? overrideTemplate]) {
    final weekdayStr = _weekdays[anchorTime.weekday - 1];
    final dateStr =
        '${anchorTime.year}-${anchorTime.month.toString().padLeft(2, '0')}-${anchorTime.day.toString().padLeft(2, '0')} '
        '${anchorTime.hour.toString().padLeft(2, '0')}:${anchorTime.minute.toString().padLeft(2, '0')}';
    final timeAnchor = '$dateStr ($weekdayStr)';

    final template = (overrideTemplate != null && overrideTemplate.trim().isNotEmpty)
        ? overrideTemplate
        : (customSystemPromptTemplate ?? defaultSystemPromptTemplate);

    if (template.contains('{TIME_ANCHOR}')) {
      return template.replaceAll('{TIME_ANCHOR}', timeAnchor);
    }
    if (template.contains('【当前系统时间锚点】：')) {
      return template.replaceFirst(
        RegExp(r'【当前系统时间锚点】：.*'),
        '【当前系统时间锚点】：$timeAnchor',
      );
    }
    return '【当前系统时间锚点】：$timeAnchor\n\n$template';
  }

  /// 主提取入口（Android 与 Windows 100% 共用）
  static Future<ExtractionResult> extractFromText({
    required String rawText,
    String sourceType = 'manual',
    AIEngineMode mode = AIEngineMode.hybridAuto,
    String llmEndpoint = 'http://127.0.0.1:11434/api/generate',
    String? llmModelName,
    bool? thinkMode,
    bool? useGbnf,
    String? customSystemPrompt,
    ExtractionProgressCallback? onProgress,
    InferenceTerminalModel? terminalModel,
  }) async {
    final incomingOnProgress = onProgress;
    onProgress = (terminalModel != null && incomingOnProgress != null)
        ? ({String? stepLog, String? token, int? tokenCount}) {
            terminalModel.handleProgress(
              stepLog: stepLog,
              token: token,
              tokenCount: tokenCount,
            );
            incomingOnProgress(
              stepLog: stepLog,
              token: token,
              tokenCount: tokenCount,
            );
          }
        : (terminalModel?.progressCallback ?? incomingOnProgress);
    final sw = Stopwatch()..start();
    final now = DateTime.now();
    final prompt = buildSystemPrompt(now, customSystemPrompt);
    final deviceOrigin = Platform.isAndroid ? 'android' : 'windows';
    final effectiveThink = thinkMode ?? LocalModelManager.enableThinkMode;
    final effectiveGbnf = useGbnf ?? enableGbnfConstraint;

    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    onProgress?.call(stepLog: '[初始化] 绑定系统时间锚点: $dateStr');

    var tokenCounter = 0;

    if (mode == AIEngineMode.localLlmServer ||
        mode == AIEngineMode.hybridAuto) {
      try {
        // 自动探测本机已有的大模型（Android 沙盒 GGUF 或 Windows 本地服务）
        String targetModel = llmModelName ?? '';
        if (targetModel.isEmpty) {
          final activeModels =
              await LocalModelManager.ensureLocalRuntimeAndListModels();
          targetModel =
              activeModels.isNotEmpty ? activeModels.first : 'qwen3.5:2b';
        }

        // 1. Android 手机端：若已下载本地 .gguf 模型包，直接调用内嵌 llama.cpp (ARM64/Vulkan) 离线推理
        if (Platform.isAndroid && !llmEndpoint.endsWith('/extract')) {
          final localGguf =
              await LocalModelManager.findLocalGgufFile(targetModel);
          if (localGguf != null) {
            onProgress?.call(
              stepLog: '[路由] 激活端侧模型引擎: $targetModel (llama.cpp ARM64/Vulkan)',
            );
            if (effectiveGbnf) {
              onProgress?.call(
                stepLog: '[语法约束] 已挂载 GBNF (GGML BNF) 采样状态机，强制锁定 JSON 语法与 ISO-8601 字段',
              );
            }
            if (effectiveThink) {
              onProgress?.call(stepLog: '[模式] 开启深度思考 (Think Mode)，模型正在输出思维链...');
            } else {
              onProgress?.call(stepLog: '[模式] 免思考极速模式，强制直出 JSON 结构化日程...');
            }

            final rawJson = await LocalModelManager.runAndroidNativeInference(
              systemPrompt: prompt,
              userPrompt: rawText,
              preferredModelId: targetModel,
              thinkMode: effectiveThink,
              gbnfGrammar: effectiveGbnf
                  ? (effectiveThink
                      ? activeGbnfGrammar
                      : prefilledAgendaGbnfGrammar.trim())
                  : null,
              onToken: (tok) {
                tokenCounter++;
                onProgress?.call(token: tok, tokenCount: tokenCounter);
              },
            );

            if (rawJson != null && rawJson.isNotEmpty) {
              onProgress?.call(stepLog: '[后处理] 解析并校验 GBNF / JSON 实体有效性...');
              final androidEvents = _parseEventsFromRawJsonString(
                rawJson: rawJson,
                rawText: rawText,
                sourceType: sourceType,
                deviceOrigin: deviceOrigin,
              );
              if (androidEvents.isNotEmpty) {
                sw.stop();
                onProgress?.call(
                  stepLog: '[完成] 成功提取 ${androidEvents.length} 个日程事项 (耗时 ${sw.elapsedMilliseconds}ms)',
                );
                return ExtractionResult(
                  events: androidEvents,
                  engineUsed:
                      'Android 端侧大模型 ($targetModel · llama.cpp${effectiveGbnf ? " · GBNF" : ""}${effectiveThink ? " · 深度思考" : ""})',
                  elapsedMs: sw.elapsedMilliseconds,
                  promptPreview: prompt,
                  rawResponse: rawJson,
                );
              }
            }
          }
        }

        // 2. Windows 桌面端 或 局域网桌面算力协同接口 (/extract)
        onProgress?.call(stepLog: '[路由] 连接本地/局域网推理服务: $targetModel');
        if (effectiveGbnf && !llmEndpoint.endsWith('/extract')) {
          onProgress?.call(
            stepLog: '[语法约束] 已启用 GBNF / Structured JSON Schema 强制采样约束',
          );
        }
        final llmEvents = await _tryCallLocalLlm(
          rawText: rawText,
          systemPrompt: prompt,
          sourceType: sourceType,
          deviceOrigin: deviceOrigin,
          endpoint: llmEndpoint,
          modelName: targetModel,
          thinkMode: effectiveThink,
          useGbnf: effectiveGbnf,
          onToken: (tok) {
            tokenCounter++;
            onProgress?.call(token: tok, tokenCount: tokenCounter);
          },
        );
        if (llmEvents.isNotEmpty) {
          sw.stop();
          onProgress?.call(
            stepLog: '[完成] 成功提取 ${llmEvents.length} 个日程事项 (耗时 ${sw.elapsedMilliseconds}ms)',
          );
          return ExtractionResult(
            events: llmEvents,
            engineUsed:
                '端侧大模型 ($targetModel${effectiveGbnf ? " · GBNF" : ""}${effectiveThink ? " · 深度思考" : ""})',
            elapsedMs: sw.elapsedMilliseconds,
            promptPreview: prompt,
          );
        }
      } catch (err) {
        onProgress?.call(stepLog: '[回退] 大模型未响应，无缝切入极速中文时空规则引擎');
      }
    }

    // 使用内置中文高校通知时空解析引擎（毫秒级响应，支持多时间节点拆解）
    onProgress?.call(stepLog: '[规则引擎] 启动纯端侧中文时空启发式规则引擎 (0延迟)');
    onProgress?.call(stepLog: '[实体扫描] 正在检测相对时间词、地点与待办 Checklist...');
    final heuristicEvents = _extractWithCampusNlpRules(
      rawText: rawText,
      anchor: now,
      sourceType: sourceType,
      deviceOrigin: deviceOrigin,
    );
    onProgress?.call(stepLog: '[时间推算] 相对日期换算与 ISO-8601 格式化完成');
    sw.stop();

    onProgress?.call(
      stepLog: '[完成] 规则引擎成功提取 ${heuristicEvents.length} 个日程事项 (耗时 ${sw.elapsedMilliseconds}ms)',
    );

    return ExtractionResult(
      events: heuristicEvents,
      engineUsed: '内置端侧中文时空规则引擎 (On-Device Fast NLP)',
      elapsedMs: sw.elapsedMilliseconds,
      promptPreview: prompt,
    );
  }

  /// 构建带 GBNF 语法规则与 JSON Schema 结构化约束的推理请求载荷
  static Map<String, dynamic> _buildLlmRequestBody({
    required String modelName,
    required String systemPrompt,
    required String userPrompt,
    required bool streamMode,
    required bool thinkMode,
    required bool useGbnf,
    bool fallbackBasicJsonFormat = false,
  }) {
    final useStrictSchema = useGbnf && !fallbackBasicJsonFormat;
    return {
      'model': modelName,
      'system': systemPrompt,
      'prompt': userPrompt,
      'stream': streamMode,
      'think': thinkMode,
      // Ollama 0.5+ 将 JSON Schema 对象通过内置 llama.cpp 编译为 GBNF 采样器；回退模式下使用通用 'json'
      'format': useStrictSchema ? agendaJsonSchema : 'json',
      // 兼容原生 llama-server / llama.cpp HTTP 接口直接读取 GBNF grammar 字段
      if (useStrictSchema) 'grammar': activeGbnfGrammar,
      'options': {
        'num_ctx': LocalModelManager.contextSize,
        'num_predict':
            thinkMode ? LocalModelManager.maxThinkingTokens : 512,
        'temperature': LocalModelManager.temperature,
        'top_p': LocalModelManager.topP,
        'repeat_penalty': LocalModelManager.repeatPenalty,
      },
    };
  }

  /// 调用本地推理服务或局域网桌面算力节点（支持 GBNF / JSON Schema 强约束与旧版运行时自动回退）
  static Future<List<AgendaEvent>> _tryCallLocalLlm({
    required String rawText,
    required String systemPrompt,
    required String sourceType,
    required String deviceOrigin,
    required String endpoint,
    required String modelName,
    bool thinkMode = false,
    bool useGbnf = true,
    void Function(String token)? onToken,
  }) async {
    final client = LocalModelManager.createDirectHttpClient(
      timeout: const Duration(seconds: 3),
    );
    try {
      final uri = Uri.parse(endpoint);
      final isExtractApi = uri.path.endsWith('/extract');
      final isCompletionApi = uri.path.endsWith('/completion');

      // 1. 若显式指定 /completion 端点，直接走 llama-server 原生接口
      if (isCompletionApi) {
        return await _tryCallLlamaServerCompletion(
          client: client,
          uri: uri,
          rawText: rawText,
          systemPrompt: systemPrompt,
          sourceType: sourceType,
          deviceOrigin: deviceOrigin,
          modelName: modelName,
          useGbnf: useGbnf,
          onToken: onToken,
        );
      }

      final bool streamMode = (!isExtractApi && onToken != null);

      Future<HttpClientResponse> sendRequest({bool fallbackFormat = false}) async {
        final req = await client.postUrl(uri);
        req.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        final Map<String, dynamic> body;
        if (isExtractApi) {
          body = {'text': rawText, 'sourceType': sourceType};
        } else {
          body = _buildLlmRequestBody(
            modelName: modelName,
            systemPrompt: systemPrompt,
            userPrompt: rawText,
            streamMode: streamMode,
            thinkMode: thinkMode,
            useGbnf: useGbnf,
            fallbackBasicJsonFormat: fallbackFormat,
          );
        }
        req.add(utf8.encode(jsonEncode(body)));
        return req.close().timeout(Duration(seconds: thinkMode ? 70 : 30));
      }

      var resp = await sendRequest();

      // 2. 若对默认端口请求返回 404，自适应无缝重定向至 llama-server 原生 /completion 接口
      if (resp.statusCode == 404 && !isExtractApi) {
        await resp.drain();
        final completionUri = uri.replace(path: '/completion');
        try {
          final llamaServerEvents = await _tryCallLlamaServerCompletion(
            client: client,
            uri: completionUri,
            rawText: rawText,
            systemPrompt: systemPrompt,
            sourceType: sourceType,
            deviceOrigin: deviceOrigin,
            modelName: modelName,
            useGbnf: useGbnf,
            onToken: onToken,
          );
          if (llamaServerEvents.isNotEmpty) {
            return llamaServerEvents;
          }
        } catch (_) {}
        return [];
      }

      // 若旧版服务端不支持 JSON Schema 对象格式返回 400/500，自动无缝降级为 'format': 'json' 重试一次
      if (resp.statusCode != 200 && !isExtractApi && useGbnf) {
        await resp.drain();
        resp = await sendRequest(fallbackFormat: true);
      }
      if (resp.statusCode != 200) return [];

      if (!isExtractApi) {
        LocalModelManager.markLoaded(modelName);
      }

      if (streamMode) {
        final fullResponse = StringBuffer();
        final thinkingBuffer = StringBuffer();
        await for (final line in resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (line.trim().isEmpty) continue;
          try {
            final parsed = jsonDecode(line);
            if (parsed is Map) {
              // 深度思考模式下同时向终端回显 thinking 思维链流，但不混入最终 JSON 缓冲区
              if (parsed.containsKey('thinking')) {
                final thinkTok = parsed['thinking']?.toString() ?? '';
                if (thinkTok.isNotEmpty) {
                  thinkingBuffer.write(thinkTok);
                  onToken(thinkTok);
                }
              }
              if (parsed.containsKey('response')) {
                final tok = parsed['response']?.toString() ?? '';
                if (tok.isNotEmpty) {
                  fullResponse.write(tok);
                  onToken(tok);
                }
              }
            }
          } catch (_) {}
        }

        var rawJsonResponse = fullResponse.toString().trim();

        // 🚨 Windows/Ollama 思考截断抢救：若思考耗尽了 token 预算导致 response 为空，自动以免思考模式基于已有思考草稿补完 JSON
        if (thinkMode &&
            (rawJsonResponse.isEmpty || !rawJsonResponse.contains('{')) &&
            thinkingBuffer.isNotEmpty &&
            !isExtractApi) {
          onToken(
            '\n\n[知程调度] ⚠️ 思考预算耗尽，正在基于已有思维链自动抢救直出日程 JSON...\n',
          );
          try {
            final rescuePrompt = '$rawText\n\n'
                '【前置思考推理草稿如下，请直接基于此草稿输出完整日程 JSON，严禁重复思考】：\n'
                '${thinkingBuffer.toString()}';

            final rescueReq = await client.postUrl(uri);
            rescueReq.headers.contentType =
                ContentType('application', 'json', charset: 'utf-8');
            final rescueBody = _buildLlmRequestBody(
              modelName: modelName,
              systemPrompt: systemPrompt,
              userPrompt: rescuePrompt,
              streamMode: true,
              thinkMode: false,
              useGbnf: useGbnf,
            );
            rescueReq.add(utf8.encode(jsonEncode(rescueBody)));
            final rescueResp = await rescueReq
                .close()
                .timeout(const Duration(seconds: 40));
            if (rescueResp.statusCode == 200) {
              final rescueBuf = StringBuffer();
              await for (final l in rescueResp
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())) {
                if (l.trim().isEmpty) continue;
                try {
                  final p = jsonDecode(l);
                  if (p is Map && p.containsKey('response')) {
                    final t = p['response']?.toString() ?? '';
                    if (t.isNotEmpty) {
                      rescueBuf.write(t);
                      onToken(t);
                    }
                  }
                } catch (_) {}
              }
              if (rescueBuf.isNotEmpty) {
                rawJsonResponse = rescueBuf.toString();
              }
            }
          } catch (_) {}
        }

        LocalModelManager.markLoaded(modelName);
        return _parseEventsFromRawJsonString(
          rawJson: rawJsonResponse,
          rawText: rawText,
          sourceType: sourceType,
          deviceOrigin: deviceOrigin,
        );
      }

      final respText = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(respText);

      // 1. 兼容局域网协同接口返回格式
      if (decoded is Map && decoded['events'] is List) {
        return (decoded['events'] as List)
            .map((e) => AgendaEvent.fromJson(
                _normalizeEventMapForGbnfSpec(Map<String, dynamic>.from(e as Map))))
            .toList();
      }

      // 2. 解析本地大模型返回的 response 字段
      final responseContent =
          (decoded is Map ? decoded['response']?.toString() : null) ?? respText;
      return _parseEventsFromRawJsonString(
        rawJson: responseContent,
        rawText: rawText,
        sourceType: sourceType,
        deviceOrigin: deviceOrigin,
      );
    } finally {
      client.close();
    }
  }

  /// 向 llama.cpp 官方预编译 llama-server 原生 /completion 发送流式推理请求并收集完整响应
  static Future<String?> _requestLlamaServerCompletion({
    required HttpClient client,
    required Uri uri,
    required String systemPrompt,
    required String userPrompt,
    required bool useGbnf,
    void Function(String token)? onToken,
    void Function(String log)? onLog,
  }) async {
    final fullPrompt = '<|im_start|>system\n'
        '$systemPrompt<|im_end|>\n'
        '<|im_start|>user\n'
        '$userPrompt<|im_end|>\n'
        '<|im_start|>assistant\n';

    Future<HttpClientResponse> doSend({bool includeConstraint = true}) async {
      final req = await client.postUrl(uri);
      req.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      final body = <String, dynamic>{
        'prompt': fullPrompt,
        'stream': onToken != null,
        'temperature': 0.1,
        'n_predict': 1024,
      };
      if (useGbnf && includeConstraint) {
        // llama-server 优先使用 json_schema（由底层 llama.cpp C++ 原生编译为 GBNF 采样器，杜绝语法解析错误）
        body['json_schema'] = agendaJsonSchema;
      }
      req.add(utf8.encode(jsonEncode(body)));
      return req.close().timeout(const Duration(seconds: 50));
    }

    var resp = await doSend(includeConstraint: true);
    // 若特定服务端版本对 json_schema 报错 400，自动免约束重试一次
    if (resp.statusCode != 200 && useGbnf) {
      onLog?.call('⚠️ 服务端拒绝语法约束载荷 (HTTP ${resp.statusCode})，正在尝试无约束直出重试...');
      await resp.drain();
      resp = await doSend(includeConstraint: false);
    }
    if (resp.statusCode != 200) {
      final errText = await resp.transform(utf8.decoder).join();
      onLog?.call('❌ llama-server 错误 (HTTP ${resp.statusCode}): $errText');
      return null;
    }

    if (onToken != null) {
      final fullResponse = StringBuffer();
      await for (final line in resp
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed.startsWith('data: ')) {
          final jsonStr = trimmed.substring(6).trim();
          if (jsonStr == '[DONE]') break;
          try {
            final parsed = jsonDecode(jsonStr);
            if (parsed is Map) {
              final tok = parsed['content']?.toString() ?? '';
              if (tok.isNotEmpty) {
                fullResponse.write(tok);
                onToken(tok);
              }
              if (parsed['stop'] == true) break;
            }
          } catch (_) {}
        }
      }
      return fullResponse.toString().trim();
    } else {
      final respText = await resp.transform(utf8.decoder).join();
      try {
        final decoded = jsonDecode(respText);
        return (decoded is Map ? decoded['content']?.toString() : null) ?? respText;
      } catch (_) {
        return respText;
      }
    }
  }

  /// 调用 llama.cpp 官方预编译 llama-server 原生 /completion 接口（支持直接输入 GBNF Grammar）
  static Future<List<AgendaEvent>> _tryCallLlamaServerCompletion({
    required HttpClient client,
    required Uri uri,
    required String rawText,
    required String systemPrompt,
    required String sourceType,
    required String deviceOrigin,
    required String modelName,
    required bool useGbnf,
    void Function(String token)? onToken,
  }) async {
    final raw = await _requestLlamaServerCompletion(
      client: client,
      uri: uri,
      systemPrompt: systemPrompt,
      userPrompt: rawText,
      useGbnf: useGbnf,
      onToken: onToken,
    );
    if (raw == null || raw.isEmpty) return [];

    LocalModelManager.markLoaded(modelName);
    return _parseEventsFromRawJsonString(
      rawJson: raw,
      rawText: rawText,
      sourceType: sourceType,
      deviceOrigin: deviceOrigin,
    );
  }

  /// 对单条事件 Map 进行 GBNF 规范化修补（例如将空格分隔的日期时间修正为标准 ISO-8601 `T` 格式）
  static Map<String, dynamic> _normalizeEventMapForGbnfSpec(
      Map<String, dynamic> rawMap) {
    final map = Map<String, dynamic>.from(rawMap);
    for (final timeKey in const ['startTime', 'endTime']) {
      final val = map[timeKey]?.toString().trim();
      if (val != null && val.isNotEmpty) {
        var norm = val.replaceAll('/', '-');
        // 将 "2026-10-25 14:30" 修补为 "2026-10-25T14:30:00"
        final spaceMatch =
            RegExp(r'^(\d{4}-\d{1,2}-\d{1,2})\s+(\d{1,2}:\d{2}(?::\d{2})?)$')
                .firstMatch(norm);
        if (spaceMatch != null) {
          norm = '${spaceMatch.group(1)}T${spaceMatch.group(2)}';
        }
        // 补齐月、日、时前导零及秒位
        final isoLoose = RegExp(
                r'^(\d{4})-(\d{1,2})-(\d{1,2})T(\d{1,2}):(\d{2})(?::(\d{2}))?')
            .firstMatch(norm);
        if (isoLoose != null) {
          final y = isoLoose.group(1)!;
          final m = isoLoose.group(2)!.padLeft(2, '0');
          final d = isoLoose.group(3)!.padLeft(2, '0');
          final hh = isoLoose.group(4)!.padLeft(2, '0');
          final mm = isoLoose.group(5)!;
          final ss = isoLoose.group(6) ?? '00';
          norm = '$y-$m-${d}T$hh:$mm:$ss';
        }
        map[timeKey] = norm;
      }
    }
    if (map['checklist'] is String) {
      final str = (map['checklist'] as String).trim();
      map['checklist'] = str.isEmpty ? <String>[] : <String>[str];
    }
    return map;
  }

  /// 校验单条事件 JSON Map 是否符合 GBNF 语法与字段规范，返回违规原因（若合规返回 null）
  static String? validateEventItemAgainstGbnf(Map<String, dynamic> item) {
    const coreRequiredKeys = [
      'title',
      'startTime',
      'endTime',
    ];
    for (final k in coreRequiredKeys) {
      if (!item.containsKey(k)) {
        return '违反 GBNF 规则：缺少核心必填字段 "$k"';
      }
    }
    final title = item['title'];
    if (title is! String || title.trim().isEmpty) {
      return '违反 GBNF 规则："title" 必须为非空字符串';
    }
    final isoReg = RegExp(
      r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$',
    );
    final startStr = item['startTime']?.toString() ?? '';
    if (!isoReg.hasMatch(startStr)) {
      return '违反 GBNF 规则："startTime" ($startStr) 不符合严格 ISO-8601 格式';
    }
    final endStr = item['endTime']?.toString() ?? '';
    if (!isoReg.hasMatch(endStr)) {
      return '违反 GBNF 规则："endTime" ($endStr) 不符合严格 ISO-8601 格式';
    }
    if (item.containsKey('checklist') && item['checklist'] is! List) {
      return '违反 GBNF 规则："checklist" 必须为字符串数组';
    }
    if (item.containsKey('reminderMinutes') && item['reminderMinutes'] is! int) {
      return '违反 GBNF 规则："reminderMinutes" 必须为整数';
    }
    if (item.containsKey('confidence')) {
      final conf = item['confidence'];
      if (conf is! num || conf < 0.0 || conf > 1.0) {
        return '违反 GBNF 规则："confidence" 必须为 0.0~1.0 之间的数值';
      }
    }
    return null;
  }

  /// 将大模型输出的 JSON 字符串解析为 AgendaEvent 列表（兼容数组、对象与截断修复，绝不因局部格式异常向上抛出导致误触发规则引擎）
  static List<AgendaEvent> _parseEventsFromRawJsonString({
    required String rawJson,
    required String rawText,
    required String sourceType,
    required String deviceOrigin,
  }) {
    final trimmed = rawJson.trim();
    if (trimmed.isEmpty) return [];

    dynamic parsedJson;
    final candidates = <String>[
      trimmed,
      if (trimmed.startsWith('{"events":[') && !trimmed.endsWith(']}'))
        trimmed.endsWith(']') ? '$trimmed}' : '$trimmed]}',
    ];

    final startObj = trimmed.indexOf('{');
    final endObj = trimmed.lastIndexOf('}');
    if (startObj != -1 && endObj > startObj) {
      final sub = trimmed.substring(startObj, endObj + 1);
      candidates.add(sub);
      if (sub.startsWith('{"events":[') && !sub.endsWith(']}')) {
        candidates.add('$sub]}');
      }
    }

    for (final candidate in candidates) {
      try {
        parsedJson = jsonDecode(candidate);
        if (parsedJson != null) break;
      } catch (_) {}
    }

    List<dynamic> rawList = [];
    if (parsedJson is List) {
      rawList = parsedJson;
    } else if (parsedJson is Map) {
      if (parsedJson['events'] is List) {
        rawList = parsedJson['events'] as List;
      } else if (parsedJson.containsKey('title')) {
        rawList = [parsedJson];
      }
    }

    // 若外层 JSON 因提示词原因夹杂了额外解释文本或未闭合数组，逐个扫描提取内层包含 "title" 的独立事件 JSON 对象
    if (rawList.isEmpty) {
      rawList = _extractBalancedEventObjects(trimmed);
    }

    final events = <AgendaEvent>[];
    int itemIndex = 0;
    for (final item in rawList) {
      if (item is! Map) continue;
      try {
        final map =
            _normalizeEventMapForGbnfSpec(Map<String, dynamic>.from(item));
        map['sourceText'] = rawText;
        map['sourceType'] = sourceType;
        map['deviceOrigin'] = deviceOrigin;
        if (map['id'] == null || map['id'].toString().trim().isEmpty) {
          map['id'] = '${DateTime.now().microsecondsSinceEpoch}_$itemIndex';
        }
        itemIndex++;
        events.add(AgendaEvent.fromJson(map));
      } catch (_) {}
    }
    return events;
  }

  /// 从非标准或混杂文本的模型输出中提取独立的 `{...}` 事件对象
  static List<Map<String, dynamic>> _extractBalancedEventObjects(String text) {
    final results = <Map<String, dynamic>>[];
    int depth = 0;
    int objStart = -1;
    bool inString = false;
    bool escaped = false;

    for (int i = 0; i < text.length; i++) {
      final ch = text[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == '\\' && inString) {
        escaped = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;

      if (ch == '{') {
        if (depth == 0) {
          objStart = i;
        } else if (depth == 1 &&
            objStart != -1 &&
            text.substring(objStart, i).contains('"events"')) {
          // 进入了 {"events": [ 内部的具体事件对象
          objStart = i;
          depth = 0;
        }
        depth++;
      } else if (ch == '}') {
        if (depth > 0) {
          depth--;
          if (depth == 0 && objStart != -1) {
            final slice = text.substring(objStart, i + 1);
            if (slice.contains('"title"')) {
              try {
                final decoded = jsonDecode(slice);
                if (decoded is Map<String, dynamic> &&
                    decoded.containsKey('title')) {
                  results.add(decoded);
                }
              } catch (_) {}
            }
            objStart = -1;
          }
        }
      }
    }
    return results;
  }

  /// 深度解析大模型返回文本，提取日程对象并捕获格式/GBNF 语法诊断错误
  static ({List<AgendaEvent> events, String? parseError}) parseAndDiagnoseJson({
    required String rawJson,
    required String rawText,
    String sourceType = 'test',
    String deviceOrigin = 'local',
  }) {
    var trimmed = rawJson.trim();
    if (trimmed.isEmpty) {
      return (events: <AgendaEvent>[], parseError: '大模型返回内容为空');
    }

    // 若包含 <think>...</think> 思维链块，先剥离思维链再诊断 JSON 正文
    final thinkEnd = trimmed.indexOf('</think>');
    if (thinkEnd != -1) {
      trimmed = trimmed.substring(thinkEnd + '</think>'.length).trim();
    }

    dynamic parsedJson;
    String? lastError;

    // 1. 先尝试直接标准解码
    try {
      parsedJson = jsonDecode(trimmed);
    } catch (e) {
      lastError = e.toString();
    }

    // 2. 尝试从 markdown 代码块 ```json ... ``` 中截取
    if (parsedJson == null) {
      final codeBlockRegex =
          RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```', caseSensitive: false);
      final match = codeBlockRegex.firstMatch(trimmed);
      if (match != null) {
        try {
          parsedJson = jsonDecode(match.group(1)!);
          lastError = '注意：大模型将 JSON 包裹在 markdown 代码块中（开启 GBNF 可消除此现象）';
        } catch (e) {
          lastError = '代码块内 JSON 语法错误: $e';
        }
      }
    }

    // 3. 尝试首尾平衡大括号截取
    if (parsedJson == null) {
      final startObj = trimmed.indexOf('{');
      final endObj = trimmed.lastIndexOf('}');
      if (startObj != -1 && endObj > startObj) {
        final sub = trimmed.substring(startObj, endObj + 1);
        try {
          parsedJson = jsonDecode(sub);
          lastError = '注意：大模型在 JSON 前后输出了额外非 JSON 闲聊文字';
        } catch (e) {
          lastError = '截取外层花括号后解析仍失败: $e';
        }
      }
    }

    // 4. 尝试提取 events 数组
    List<dynamic> rawList = [];
    if (parsedJson is List) {
      rawList = parsedJson;
      lastError ??= '警告：顶层直接输出了数组而非 GBNF 规范的 {"events": [...]} 对象';
    } else if (parsedJson is Map) {
      if (parsedJson['events'] is List) {
        rawList = parsedJson['events'] as List;
      } else if (parsedJson.containsKey('title')) {
        rawList = [parsedJson];
        lastError ??= '警告：顶层直接输出了单个日程对象而非 {"events": [...]}';
      }
    }

    // 5. 兜底扫描孤立 event 对象
    if (rawList.isEmpty) {
      final fallbackObjects = _extractBalancedEventObjects(trimmed);
      if (fallbackObjects.isNotEmpty) {
        rawList = fallbackObjects;
        lastError = '警告：大模型未生成规范顶层 events 数组，仅提取出内层零散对象';
      }
    }

    final events = <AgendaEvent>[];
    int itemIndex = 0;
    for (final item in rawList) {
      if (item is! Map) continue;
      try {
        final rawItemMap = Map<String, dynamic>.from(item);
        final gbnfViolation = validateEventItemAgainstGbnf(rawItemMap);
        if (gbnfViolation != null && lastError == null) {
          lastError = gbnfViolation;
        }
        final map = _normalizeEventMapForGbnfSpec(rawItemMap);
        map['sourceText'] = rawText;
        map['sourceType'] = sourceType;
        map['deviceOrigin'] = deviceOrigin;
        if (map['id'] == null || map['id'].toString().trim().isEmpty) {
          map['id'] = '${DateTime.now().microsecondsSinceEpoch}_$itemIndex';
        }
        itemIndex++;
        events.add(AgendaEvent.fromJson(map));
      } catch (e) {
        lastError = '部分日程项字段缺失或类型错误: $e';
      }
    }

    if (events.isEmpty && lastError == null) {
      lastError = '未在输出中检测到有效的日程字段 (缺少 title / startTime 等关键键)';
    }

    final isCleanStandardJson = events.isNotEmpty &&
        parsedJson is Map &&
        parsedJson['events'] is List &&
        !trimmed.contains('```') &&
        lastError == null;

    return (
      events: events,
      parseError: isCleanStandardJson ? null : lastError,
    );
  }

  /// 专用提示词调试测试推理接口（不回退规则引擎，保留完整原始流与 GBNF 错误诊断）
  static Future<ExtractionResult> testInference({
    required String userPrompt,
    required String systemPrompt,
    String? modelName,
    String llmEndpoint = 'http://127.0.0.1:11434/api/generate',
    bool thinkMode = false,
    bool? useGbnf,
    ExtractionProgressCallback? onProgress,
    InferenceTerminalModel? terminalModel,
  }) async {
    final incomingOnProgress = onProgress;
    onProgress = (terminalModel != null && incomingOnProgress != null)
        ? ({String? stepLog, String? token, int? tokenCount}) {
            terminalModel.handleProgress(
              stepLog: stepLog,
              token: token,
              tokenCount: tokenCount,
            );
            incomingOnProgress(
              stepLog: stepLog,
              token: token,
              tokenCount: tokenCount,
            );
          }
        : (terminalModel?.progressCallback ?? incomingOnProgress);
    final sw = Stopwatch()..start();
    final now = DateTime.now();
    final prompt = buildSystemPrompt(now, systemPrompt);
    final deviceOrigin = Platform.isAndroid ? 'android' : 'windows';
    final effectiveGbnf = useGbnf ?? enableGbnfConstraint;

    onProgress?.call(stepLog: '[测试] 启动端侧模型提示词独立调试...');
    onProgress?.call(stepLog: '[注入] 已构建系统提示词 (长度: ${prompt.length} 字符)');
    if (effectiveGbnf) {
      onProgress?.call(
        stepLog: '[GBNF] 已启用 GGML BNF 强制语法约束 (严格锁定 events Schema 与 ISO-8601 时间格式)',
      );
    } else {
      onProgress?.call(stepLog: '[GBNF] 当前已关闭 GBNF 强约束，仅使用基础 JSON 模式');
    }

    var tokenCounter = 0;
    String targetModel = modelName ?? '';
    if (targetModel.isEmpty) {
      final activeModels =
          await LocalModelManager.ensureLocalRuntimeAndListModels();
      targetModel = activeModels.isNotEmpty ? activeModels.first : 'qwen3.5:2b';
    }

    try {
      // 1. Android 端侧 llama.cpp
      if (Platform.isAndroid && !llmEndpoint.endsWith('/extract')) {
        final localGguf = await LocalModelManager.findLocalGgufFile(targetModel);
        if (localGguf != null) {
          onProgress?.call(
            stepLog: '[路由] 载入内嵌引擎: $targetModel (llama.cpp)',
          );
          final rawOut = await LocalModelManager.runAndroidNativeInference(
            systemPrompt: prompt,
            userPrompt: userPrompt,
            preferredModelId: targetModel,
            thinkMode: thinkMode,
            gbnfGrammar: effectiveGbnf
                ? (thinkMode
                    ? activeGbnfGrammar
                    : prefilledAgendaGbnfGrammar.trim())
                : null,
            onToken: (tok) {
              tokenCounter++;
              onProgress?.call(token: tok, tokenCount: tokenCounter);
            },
          );
          sw.stop();
          final raw = rawOut ?? '';
          final diag = parseAndDiagnoseJson(
            rawJson: raw,
            rawText: userPrompt,
            sourceType: 'prompt_test',
            deviceOrigin: deviceOrigin,
          );
          onProgress?.call(
            stepLog:
                '[完成] 推理结束 (${sw.elapsedMilliseconds}ms)，提取到 ${diag.events.length} 个日程事项',
          );
          return ExtractionResult(
            events: diag.events,
            engineUsed:
                'Android 端侧引擎 ($targetModel${effectiveGbnf ? " · GBNF" : ""})',
            elapsedMs: sw.elapsedMilliseconds,
            promptPreview: prompt,
            rawResponse: raw,
            jsonParseError: diag.parseError,
          );
        }
      }

      // 2. Windows 桌面端或 HTTP 接口
      onProgress?.call(stepLog: '[路由] 连接本地推理引擎: $targetModel');
      final client = LocalModelManager.createDirectHttpClient(
        timeout: const Duration(seconds: 4),
      );
      try {
        final uri = Uri.parse(llmEndpoint);
        final isCompletionApi = uri.path.endsWith('/completion');

        // 1. 若显式指定 /completion 端点，直接走 llama-server 原生接口
        if (isCompletionApi) {
          onProgress?.call(stepLog: '[协议] 使用 llama.cpp 原生 /completion 流式接口');
          final raw = await _requestLlamaServerCompletion(
            client: client,
            uri: uri,
            systemPrompt: prompt,
            userPrompt: userPrompt,
            useGbnf: effectiveGbnf,
            onToken: (tok) {
              tokenCounter++;
              onProgress?.call(token: tok, tokenCount: tokenCounter);
            },
            onLog: (l) => onProgress?.call(stepLog: l),
          );
          if (raw == null || raw.isEmpty) {
            throw Exception('llama-server 未返回有效响应，请确认后台服务状态');
          }
          LocalModelManager.markLoaded(targetModel);
          sw.stop();
          final diag = parseAndDiagnoseJson(
            rawJson: raw,
            rawText: userPrompt,
            sourceType: 'prompt_test',
            deviceOrigin: deviceOrigin,
          );
          onProgress?.call(
            stepLog:
                '[完成] 推理结束 (${sw.elapsedMilliseconds}ms)，提取到 ${diag.events.length} 个日程事项',
          );
          return ExtractionResult(
            events: diag.events,
            engineUsed:
                'llama-server ($targetModel${effectiveGbnf ? " · GBNF" : ""})',
            elapsedMs: sw.elapsedMilliseconds,
            promptPreview: prompt,
            rawResponse: raw,
            jsonParseError: diag.parseError,
          );
        }

        Future<HttpClientResponse> sendTestReq({bool fallbackFormat = false}) async {
          final req = await client.postUrl(uri);
          req.headers.contentType =
              ContentType('application', 'json', charset: 'utf-8');
          final body = _buildLlmRequestBody(
            modelName: targetModel,
            systemPrompt: prompt,
            userPrompt: userPrompt,
            streamMode: true,
            thinkMode: thinkMode,
            useGbnf: effectiveGbnf,
            fallbackBasicJsonFormat: fallbackFormat,
          );
          req.add(utf8.encode(jsonEncode(body)));
          return req.close().timeout(Duration(seconds: thinkMode ? 75 : 40));
        }

        var resp = await sendTestReq();

        // 2. 自适应：若请求 404，表明后台是 llama-server，自动无缝重定向至 /completion 接口
        if (resp.statusCode == 404) {
          await resp.drain();
          onProgress?.call(
            stepLog: '[自适应] 目标为 llama-server 原生端点，自动重定向至 /completion 接口...',
          );
          final completionUri = uri.replace(path: '/completion');
          final raw = await _requestLlamaServerCompletion(
            client: client,
            uri: completionUri,
            systemPrompt: prompt,
            userPrompt: userPrompt,
            useGbnf: effectiveGbnf,
            onToken: (tok) {
              tokenCounter++;
              onProgress?.call(token: tok, tokenCount: tokenCounter);
            },
            onLog: (l) => onProgress?.call(stepLog: l),
          );
          if (raw != null && raw.isNotEmpty) {
            LocalModelManager.markLoaded(targetModel);
            sw.stop();
            final diag = parseAndDiagnoseJson(
              rawJson: raw,
              rawText: userPrompt,
              sourceType: 'prompt_test',
              deviceOrigin: deviceOrigin,
            );
            onProgress?.call(
              stepLog:
                  '[完成] 推理结束 (${sw.elapsedMilliseconds}ms)，提取到 ${diag.events.length} 个日程事项',
            );
            return ExtractionResult(
              events: diag.events,
              engineUsed:
                  'llama-server ($targetModel${effectiveGbnf ? " · GBNF" : ""})',
              elapsedMs: sw.elapsedMilliseconds,
              promptPreview: prompt,
              rawResponse: raw,
              jsonParseError: diag.parseError,
            );
          }
          throw Exception('llama-server /completion 未响应数据');
        }

        if (resp.statusCode != 200 && effectiveGbnf) {
          onProgress?.call(
            stepLog: '[兼容] 服务端不支持 Schema 对象格式，自动回退至基础 JSON 格式重试...',
          );
          await resp.drain();
          resp = await sendTestReq(fallbackFormat: true);
        }
        if (resp.statusCode != 200) {
          throw Exception('服务端返回状态码: ${resp.statusCode}');
        }
        LocalModelManager.markLoaded(targetModel);

        final fullResponse = StringBuffer();
        await for (final line in resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (line.trim().isEmpty) continue;
          try {
            final parsed = jsonDecode(line);
            if (parsed is Map) {
              if (parsed.containsKey('thinking')) {
                final thinkTok = parsed['thinking']?.toString() ?? '';
                if (thinkTok.isNotEmpty) {
                  tokenCounter++;
                  onProgress?.call(token: thinkTok, tokenCount: tokenCounter);
                }
              }
              if (parsed.containsKey('response')) {
                final tok = parsed['response']?.toString() ?? '';
                if (tok.isNotEmpty) {
                  fullResponse.write(tok);
                  tokenCounter++;
                  onProgress?.call(token: tok, tokenCount: tokenCounter);
                }
              }
            }
          } catch (_) {}
        }
        sw.stop();
        final raw = fullResponse.toString();
        final diag = parseAndDiagnoseJson(
          rawJson: raw,
          rawText: userPrompt,
          sourceType: 'prompt_test',
          deviceOrigin: deviceOrigin,
        );
        onProgress?.call(
          stepLog:
              '[完成] 推理结束 (${sw.elapsedMilliseconds}ms)，提取到 ${diag.events.length} 个日程事项',
        );
        return ExtractionResult(
          events: diag.events,
          engineUsed: '端侧大模型 ($targetModel${effectiveGbnf ? " · GBNF" : ""})',
          elapsedMs: sw.elapsedMilliseconds,
          promptPreview: prompt,
          rawResponse: raw,
          jsonParseError: diag.parseError,
        );
      } finally {
        client.close();
      }
    } catch (e) {
      sw.stop();
      onProgress?.call(stepLog: '[错误] 推理调试失败: $e');
      return ExtractionResult(
        events: [],
        engineUsed: '调试失败',
        elapsedMs: sw.elapsedMilliseconds,
        promptPreview: prompt,
        rawResponse: '',
        jsonParseError: '推理异常: $e',
      );
    }
  }

  /// 内置高校通知多节点时空启发式解析器（支持一段通知拆出多个日程节点）
  static List<AgendaEvent> _extractWithCampusNlpRules({
    required String rawText,
    required DateTime anchor,
    required String sourceType,
    required String deviceOrigin,
  }) {
    final text = rawText.trim();
    if (text.isEmpty) return [];

    // 1. 提取全局主题前缀（如【教务通知】、【AI开源大赛】等）
    String globalPrefix = '';
    final bracketMatch = RegExp(r'【([^】]{2,20})】').firstMatch(text);
    if (bracketMatch != null) {
      globalPrefix = bracketMatch.group(1)!.trim();
    }

    // 2. 提取全局待办事项 Checklist
    final checklist = <String>[];
    final todoPatterns = [
      RegExp(r'(?:请携带|需携带|准备好|务必带上|请提交|需提交|记得带)([^。；！\n]{2,35})'),
      RegExp(r'(?:报名方式|提交材料|要求)[:：]\s*([^。；\n]{3,40})'),
    ];
    for (final reg in todoPatterns) {
      for (final m in reg.allMatches(text)) {
        final item = m.group(1)?.trim();
        if (item != null && !checklist.contains(item)) {
          checklist.add(item);
        }
      }
    }

    // 3. 将长通知按句号、分号、换行或编号切分为子句，支持多时间节点提取
    final segments = text
        .split(RegExp(r'[。\n；;！!]|\d+[\.、\)]'))
        .map((s) => s.trim())
        .where((s) => s.length >= 4)
        .toList();

    final results = <AgendaEvent>[];
    final globalLocation = _extractLocation(text);

    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final parsedTime = _parseDateTimeFromSegment(seg, anchor);
      if (parsedTime != null) {
        final loc = _extractLocation(seg).isNotEmpty
            ? _extractLocation(seg)
            : globalLocation;
        final title = _inferEventTitle(seg, globalPrefix);
        results.add(
          AgendaEvent(
            id: '${anchor.microsecondsSinceEpoch}_$i',
            title: title,
            startTime: parsedTime.start,
            endTime: parsedTime.end,
            location: loc,
            description: seg,
            sourceText: text,
            sourceType: sourceType,
            reminderMinutes: seg.contains('截止') ? 60 : 30,
            checklist: List<String>.from(checklist),
            confidence: 0.94,
            deviceOrigin: deviceOrigin,
          ),
        );
      }
    }

    // 如果分段未匹配到特定时间，对全文做一次兜底时间提取
    if (results.isEmpty) {
      final fallbackTime = _parseDateTimeFromSegment(text, anchor) ??
          _TimeSpan(
            DateTime(anchor.year, anchor.month, anchor.day, anchor.hour + 1, 0),
            DateTime(anchor.year, anchor.month, anchor.day, anchor.hour + 2, 0),
          );
      results.add(
        AgendaEvent(
          id: anchor.microsecondsSinceEpoch.toString(),
          title: _inferEventTitle(text, globalPrefix),
          startTime: fallbackTime.start,
          endTime: fallbackTime.end,
          location: globalLocation,
          description: text.length > 100 ? '${text.substring(0, 100)}...' : text,
          sourceText: text,
          sourceType: sourceType,
          checklist: checklist,
          confidence: 0.82,
          deviceOrigin: deviceOrigin,
        ),
      );
    }

    return results;
  }

  static _TimeSpan? _parseDateTimeFromSegment(String seg, DateTime anchor) {
    DateTime? targetDate;

    // A. 匹配显式月日：如 10月20日、10月25号、2026-10-20、10/20
    final explicitDate =
        RegExp(r'(?:(\d{4})[年\-/])?(\d{1,2})[月\-/](\d{1,2})[日号]?')
            .firstMatch(seg);
    if (explicitDate != null) {
      final year = int.tryParse(explicitDate.group(1) ?? '') ?? anchor.year;
      final month = int.tryParse(explicitDate.group(2)!) ?? anchor.month;
      final day = int.tryParse(explicitDate.group(3)!) ?? anchor.day;
      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        targetDate = DateTime(year, month, day);
      }
    }

    // B. 匹配相对日期：今天、明天、后天、大后天
    if (targetDate == null) {
      if (seg.contains('大后天')) {
        targetDate = DateTime(anchor.year, anchor.month, anchor.day + 3);
      } else if (seg.contains('后天')) {
        targetDate = DateTime(anchor.year, anchor.month, anchor.day + 2);
      } else if (seg.contains('明天') || seg.contains('明日')) {
        targetDate = DateTime(anchor.year, anchor.month, anchor.day + 1);
      } else if (seg.contains('今天') || seg.contains('今日') || seg.contains('今晚')) {
        targetDate = DateTime(anchor.year, anchor.month, anchor.day);
      }
    }

    // C. 匹配相对周几：本周五、下周三、周日等
    if (targetDate == null) {
      final weekMatch =
          RegExp(r'(本周|这周|下周|星期|周|礼拜)([一二三四五六日天])').firstMatch(seg);
      if (weekMatch != null) {
        final prefix = weekMatch.group(1)!;
        final dayChar = weekMatch.group(2)!;
        const map = {
          '一': 1,
          '二': 2,
          '三': 3,
          '四': 4,
          '五': 5,
          '六': 6,
          '日': 7,
          '天': 7
        };
        final targetWeekday = map[dayChar] ?? anchor.weekday;
        int delta = targetWeekday - anchor.weekday;
        if (prefix == '下周') {
          delta += 7;
        } else if (delta < 0) {
          delta += 7;
        }
        targetDate = DateTime(anchor.year, anchor.month, anchor.day + delta);
      }
    }

    if (targetDate == null) return null;

    // D. 提取具体几点几分
    int hour = 9;
    int minute = 0;
    int endHour = 10;
    int endMinute = 0;

    final isPm = seg.contains('下午') ||
        seg.contains('晚上') ||
        seg.contains('晚') ||
        seg.contains('傍晚');
    if (seg.contains('晚上') || seg.contains('今晚')) {
      hour = 19;
      endHour = 20;
    } else if (seg.contains('下午')) {
      hour = 14;
      endHour = 15;
    } else if (seg.contains('中午')) {
      hour = 12;
      endHour = 13;
    } else if (seg.contains('截止') || seg.contains('前提交') || seg.contains('前交')) {
      hour = 23;
      minute = 59;
      endHour = 23;
      endMinute = 59;
    }

    // 匹配形如 14:30 - 16:00 或 19:00 或 下午2点半
    final rangeTime =
        RegExp(r'(\d{1,2})[:：点时](\d{1,2}|半)?\s*[-~至到]\s*(\d{1,2})[:：点时](\d{1,2}|半)?')
            .firstMatch(seg);
    if (rangeTime != null) {
      hour = int.parse(rangeTime.group(1)!);
      final m1 = rangeTime.group(2);
      minute = m1 == '半' ? 30 : (int.tryParse(m1 ?? '0') ?? 0);
      endHour = int.parse(rangeTime.group(3)!);
      final m2 = rangeTime.group(4);
      endMinute = m2 == '半' ? 30 : (int.tryParse(m2 ?? '0') ?? 0);
      if (isPm && hour < 12) hour += 12;
      if (isPm && endHour < 12) endHour += 12;
    } else {
      final singleTime =
          RegExp(r'(\d{1,2}|[一二三四五六七八九十]{1,2})[:：点时](\d{1,2}|半)?')
              .firstMatch(seg);
      if (singleTime != null) {
        hour = _parseChineseOrArabicNumber(singleTime.group(1)!);
        final m = singleTime.group(2);
        minute = m == '半' ? 30 : (int.tryParse(m ?? '0') ?? 0);
        if (isPm && hour < 12) hour += 12;
        endHour = (hour + 1).clamp(0, 23);
        endMinute = minute;
      }
    }

    final start =
        DateTime(targetDate.year, targetDate.month, targetDate.day, hour, minute);
    final end = DateTime(
        targetDate.year, targetDate.month, targetDate.day, endHour, endMinute);
    return _TimeSpan(
      start,
      end.isAfter(start) ? end : start.add(const Duration(hours: 1)),
    );
  }

  static int _parseChineseOrArabicNumber(String raw) {
    final parsed = int.tryParse(raw);
    if (parsed != null) return parsed;
    const cnMap = {
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '十': 10,
      '十一': 11,
      '十二': 12,
    };
    return cnMap[raw] ?? 9;
  }

  static String _extractLocation(String text) {
    final patterns = [
      RegExp(r'(?:地点|教室|会场|会议室|位置)[:：为是]?\s*([^\s，,。；;\n]{2,25})'),
      RegExp(r'(?:腾讯会议|飞书会议|Zoom|钉钉会议)[:：号ID\s]*([0-9\-]{6,15})',
          caseSensitive: false),
      RegExp(r'在([^\s，,。；;\n]{2,18}?(?:楼|教室|报告厅|会议室|馆|中心|操场|实验室)[A-Za-z0-9\-室号]*)'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        final matched = m.group(0)!;
        if (matched.contains('会议') && RegExp(r'\d{3}').hasMatch(matched)) {
          return matched.trim();
        }
        return m.group(1)!.trim();
      }
    }
    return '';
  }

  static String _inferEventTitle(String seg, String globalPrefix) {
    // 清理时间与地点修饰词，提炼核心事件名
    var cleaned = seg
        .replaceAll(RegExp(r'【[^】]+】'), '')
        .replaceAll(
            RegExp(r'(?:全体同学|各位同学|通知|请注意|收到请回复|务必准时)[:：，,]?'), '')
        .trim();

    // 寻找关键词短语
    final actionMatch = RegExp(
            r'(?:举行|召开|开展|进行|参加|提交|举办|开启|安排)([^，,。；;\n]{2,18})')
        .firstMatch(cleaned);
    String core = '';
    if (actionMatch != null) {
      core = actionMatch.group(1)!.trim();
    } else if (cleaned.contains('截止')) {
      final idx = cleaned.indexOf('截止');
      final start = (idx - 10).clamp(0, idx);
      core = '${cleaned.substring(start, idx)}截止';
    } else {
      // 去除开头的时间描述
      cleaned = cleaned.replaceFirst(
          RegExp(
              r'^.*?(?:今天|明天|后天|本周[一二三四五六日天]|下周[一二三四五六日天]|\d{1,2}月\d{1,2}[日号])\s*(?:上午|下午|晚上|中午)?\s*(?:\d{1,2}[:：点时]\d{0,2}半?)?\s*'),
          '');
      cleaned = cleaned.replaceFirst(RegExp(r'^在[^\s，,。]{2,15}'), '').trim();
      core = cleaned.length > 18 ? cleaned.substring(0, 18) : cleaned;
    }

    if (core.isEmpty) core = '校园日程事项';
    if (globalPrefix.isNotEmpty && !core.contains(globalPrefix)) {
      return '[$globalPrefix] $core';
    }
    return core;
  }
}

class _TimeSpan {
  final DateTime start;
  final DateTime end;
  _TimeSpan(this.start, this.end);
}
