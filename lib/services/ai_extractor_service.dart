import 'dart:convert';
import 'dart:io';
import '../models/agenda_event.dart';
import 'local_model_manager.dart';

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

  ExtractionResult({
    required this.events,
    required this.engineUsed,
    required this.elapsedMs,
    required this.promptPreview,
  });
}

typedef ExtractionProgressCallback = void Function({
  String? stepLog,
  String? token,
  int? tokenCount,
});

class AIExtractorService {
  /// 全局共享的当前引擎模式（由设置或工作台界面动态切换）
  static AIEngineMode currentEngineMode = AIEngineMode.hybridAuto;

  /// 全局共享的当前偏好模型 ID（如 qwen3.5:2b）
  static String? currentPreferredModel;

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
  static String buildSystemPrompt(DateTime anchorTime) {
    final weekdayStr = _weekdays[anchorTime.weekday - 1];
    final dateStr =
        '${anchorTime.year}-${anchorTime.month.toString().padLeft(2, '0')}-${anchorTime.day.toString().padLeft(2, '0')} '
        '${anchorTime.hour.toString().padLeft(2, '0')}:${anchorTime.minute.toString().padLeft(2, '0')}';

    return '''你是一个运行在端侧设备的高校通知日程提取助手。
【当前系统时间锚点】：$dateStr ($weekdayStr)
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
  }

  /// 主提取入口（Android 与 Windows 100% 共用）
  static Future<ExtractionResult> extractFromText({
    required String rawText,
    String sourceType = 'manual',
    AIEngineMode mode = AIEngineMode.hybridAuto,
    String llmEndpoint = 'http://127.0.0.1:11434/api/generate',
    String? llmModelName,
    bool? thinkMode,
    ExtractionProgressCallback? onProgress,
  }) async {
    final sw = Stopwatch()..start();
    final now = DateTime.now();
    final prompt = buildSystemPrompt(now);
    final deviceOrigin = Platform.isAndroid ? 'android' : 'windows';
    final effectiveThink = thinkMode ?? LocalModelManager.enableThinkMode;

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
              onToken: (tok) {
                tokenCounter++;
                onProgress?.call(token: tok, tokenCount: tokenCounter);
              },
            );

            if (rawJson != null && rawJson.isNotEmpty) {
              onProgress?.call(stepLog: '[后处理] 解析并校验 JSON 实体有效性...');
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
                      'Android 端侧大模型 ($targetModel · llama.cpp${effectiveThink ? " · 深度思考" : ""})',
                  elapsedMs: sw.elapsedMilliseconds,
                  promptPreview: prompt,
                );
              }
            }
          }
        }

        // 2. Windows 桌面端 或 局域网桌面算力协同接口 (/extract)
        onProgress?.call(stepLog: '[路由] 连接本地/局域网推理服务: $targetModel');
        final llmEvents = await _tryCallLocalLlm(
          rawText: rawText,
          systemPrompt: prompt,
          sourceType: sourceType,
          deviceOrigin: deviceOrigin,
          endpoint: llmEndpoint,
          modelName: targetModel,
          thinkMode: effectiveThink,
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
            engineUsed: '端侧大模型 ($targetModel${effectiveThink ? " · 深度思考" : ""})',
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

  /// 调用本地推理服务或局域网桌面算力节点
  static Future<List<AgendaEvent>> _tryCallLocalLlm({
    required String rawText,
    required String systemPrompt,
    required String sourceType,
    required String deviceOrigin,
    required String endpoint,
    required String modelName,
    bool thinkMode = false,
    void Function(String token)? onToken,
  }) async {
    final client = LocalModelManager.createDirectHttpClient(
      timeout: const Duration(seconds: 3),
    );
    try {
      final uri = Uri.parse(endpoint);
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');

      final isExtractApi = uri.path.endsWith('/extract');
      final bool streamMode = (!isExtractApi && onToken != null);

      final Map<String, dynamic> body;
      if (isExtractApi) {
        body = {'text': rawText, 'sourceType': sourceType};
      } else {
        body = {
          'model': modelName,
          'system': systemPrompt,
          'prompt': rawText,
          'stream': streamMode,
          'think': thinkMode,
          'format': 'json',
        };
      }

      req.add(utf8.encode(jsonEncode(body)));
      final resp = await req.close().timeout(Duration(seconds: thinkMode ? 70 : 30));
      if (resp.statusCode != 200) return [];

      if (!isExtractApi) {
        LocalModelManager.markLoaded(modelName);
      }

      if (streamMode) {
        final fullResponse = StringBuffer();
        await for (final line in resp.transform(utf8.decoder).transform(const LineSplitter())) {
          if (line.trim().isEmpty) continue;
          try {
            final parsed = jsonDecode(line);
            if (parsed is Map && parsed.containsKey('response')) {
              final tok = parsed['response']?.toString() ?? '';
              fullResponse.write(tok);
              onToken(tok);
            }
          } catch (_) {}
        }
        LocalModelManager.markLoaded(modelName);
        return _parseEventsFromRawJsonString(
          rawJson: fullResponse.toString(),
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
            .map((e) => AgendaEvent.fromJson(e as Map<String, dynamic>))
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

  /// 将大模型输出的 JSON 字符串解析为 AgendaEvent 列表（兼容数组与对象结构）
  static List<AgendaEvent> _parseEventsFromRawJsonString({
    required String rawJson,
    required String rawText,
    required String sourceType,
    required String deviceOrigin,
  }) {
    final trimmed = rawJson.trim();
    dynamic parsedJson;
    try {
      parsedJson = jsonDecode(trimmed);
    } catch (_) {
      final startObj = trimmed.indexOf('{');
      final endObj = trimmed.lastIndexOf('}');
      if (startObj != -1 && endObj > startObj) {
        parsedJson = jsonDecode(trimmed.substring(startObj, endObj + 1));
      } else {
        return [];
      }
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

    return rawList.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      map['sourceText'] = rawText;
      map['sourceType'] = sourceType;
      map['deviceOrigin'] = deviceOrigin;
      return AgendaEvent.fromJson(map);
    }).toList();
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
