import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'ai_extractor_service.dart';
import 'local_model_manager.dart';
import 'platform_bridge.dart';

/// 全局应用设置持久化服务（管理模型推理参数、思考模式、常驻释放、协同 IP 与引擎路由等）
class AppSettingsService {
  static final AppSettingsService _instance = AppSettingsService._internal();
  factory AppSettingsService() => _instance;
  static AppSettingsService get instance => _instance;

  AppSettingsService._internal();

  File? _settingsFile;
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  // --- 配置项定义及默认值 ---
  AIEngineMode _engineMode = AIEngineMode.hybridAuto;
  int _idleUnloadMinutes = 5;
  bool _enableThinkMode = false;
  bool _autoPreloadOnOverlayExpand = true;
  bool _enableGbnfConstraint = true;
  String? _preferredModel;
  String _llmEndpoint = 'http://127.0.0.1:11434/api/generate';
  String _peerIp = '';
  bool _syncDeleteFromSystemCalendar = true;

  // 高级模型推理与采样参数
  int _contextSize = 2048;
  int _maxThinkingTokens = 1536;
  double _temperature = 0.30;
  double _topP = 0.90;
  double _repeatPenalty = 1.10;

  // Getters
  AIEngineMode get engineMode => _engineMode;
  int get idleUnloadMinutes => _idleUnloadMinutes;
  bool get enableThinkMode => _enableThinkMode;
  bool get autoPreloadOnOverlayExpand => _autoPreloadOnOverlayExpand;
  bool get enableGbnfConstraint => _enableGbnfConstraint;
  String? get preferredModel => _preferredModel;
  String get llmEndpoint => _llmEndpoint;
  String get peerIp => _peerIp;
  bool get syncDeleteFromSystemCalendar => _syncDeleteFromSystemCalendar;
  int get contextSize => _contextSize;
  int get maxThinkingTokens => _maxThinkingTokens;
  double get temperature => _temperature;
  double get topP => _topP;
  double get repeatPenalty => _repeatPenalty;

  // --- 边界常量定义 ---
  static const int minContextSize = 512;
  static const int maxContextSize = 32768;
  static const int defaultContextSize = 2048;

  static const int minThinkingTokens = 128;
  static const int maxThinkingTokensLimit = 4096;
  static const int defaultThinkingTokens = 1536;

  static const double minTemperature = 0.0;
  static const double maxTemperature = 1.5;
  static const double defaultTemperature = 0.30;

  static const double minTopP = 0.1;
  static const double maxTopP = 1.0;
  static const double defaultTopP = 0.90;

  static const double minRepeatPenalty = 1.0;
  static const double maxRepeatPenalty = 2.0;
  static const double defaultRepeatPenalty = 1.10;

  Future<File> _resolveSettingsFile([String? baseDir]) async {
    if (baseDir != null && baseDir.isNotEmpty) {
      _settingsFile = File('$baseDir${Platform.pathSeparator}app_settings.json');
      return _settingsFile!;
    }
    if (_settingsFile != null) return _settingsFile!;

    String dir = Directory.current.path;
    if (Platform.isAndroid) {
      try {
        final storageDir = await PlatformBridge.getAppStorageDir();
        if (storageDir != null && storageDir.isNotEmpty) {
          dir = storageDir;
        }
      } catch (_) {}
    }
    _settingsFile = File('$dir${Platform.pathSeparator}app_settings.json');
    return _settingsFile!;
  }

  /// 初始化并从本地加载所有已保存的设置
  Future<void> init([String? storageDir]) async {
    try {
      final file = await _resolveSettingsFile(storageDir);
      if (await file.exists()) {
        final text = await file.readAsString();
        if (text.trim().isNotEmpty) {
          final dynamic decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic>) {
            if (decoded.containsKey('engineMode')) {
              final modeStr = decoded['engineMode']?.toString();
              _engineMode = switch (modeStr) {
                'builtInRuleEngine' => AIEngineMode.builtInRuleEngine,
                'localLlmServer' => AIEngineMode.localLlmServer,
                _ => AIEngineMode.hybridAuto,
              };
            }
            if (decoded.containsKey('idleUnloadMinutes')) {
              _idleUnloadMinutes = decoded['idleUnloadMinutes'] as int? ?? 5;
            }
            if (decoded.containsKey('enableThinkMode')) {
              _enableThinkMode = decoded['enableThinkMode'] as bool? ?? false;
            }
            if (decoded.containsKey('autoPreloadOnOverlayExpand')) {
              _autoPreloadOnOverlayExpand =
                  decoded['autoPreloadOnOverlayExpand'] as bool? ?? true;
            }
            if (decoded.containsKey('enableGbnfConstraint')) {
              _enableGbnfConstraint =
                  decoded['enableGbnfConstraint'] as bool? ?? true;
            }
            if (decoded.containsKey('preferredModel')) {
              _preferredModel = decoded['preferredModel']?.toString();
            }
            if (decoded.containsKey('llmEndpoint')) {
              _llmEndpoint =
                  decoded['llmEndpoint']?.toString() ?? _llmEndpoint;
            }
            if (decoded.containsKey('peerIp')) {
              _peerIp = decoded['peerIp']?.toString() ?? '';
            }
            if (decoded.containsKey('syncDeleteFromSystemCalendar')) {
              _syncDeleteFromSystemCalendar =
                  decoded['syncDeleteFromSystemCalendar'] as bool? ?? true;
            }
            if (decoded.containsKey('contextSize')) {
              _contextSize = (decoded['contextSize'] as num?)
                      ?.toInt()
                      .clamp(minContextSize, maxContextSize) ??
                  defaultContextSize;
            }
            if (decoded.containsKey('maxThinkingTokens')) {
              _maxThinkingTokens = (decoded['maxThinkingTokens'] as num?)
                      ?.toInt()
                      .clamp(minThinkingTokens, maxThinkingTokensLimit) ??
                  defaultThinkingTokens;
            }
            if (decoded.containsKey('temperature')) {
              _temperature = (decoded['temperature'] as num?)
                      ?.toDouble()
                      .clamp(minTemperature, maxTemperature) ??
                  defaultTemperature;
            }
            if (decoded.containsKey('topP')) {
              _topP = (decoded['topP'] as num?)
                      ?.toDouble()
                      .clamp(minTopP, maxTopP) ??
                  defaultTopP;
            }
            if (decoded.containsKey('repeatPenalty')) {
              _repeatPenalty = (decoded['repeatPenalty'] as num?)
                      ?.toDouble()
                      .clamp(minRepeatPenalty, maxRepeatPenalty) ??
                  defaultRepeatPenalty;
            }
          }
        }
      }
      _syncToServices();
      _isInitialized = true;
    } catch (e) {
      debugPrint('[AppSettingsService] 初始化配置异常: $e');
    }
  }

  /// 将已加载的配置同步到各业务模块的静态变量中
  void _syncToServices() {
    AIExtractorService.currentEngineMode = _engineMode;
    AIExtractorService.currentPreferredModel = _preferredModel;
    AIExtractorService.currentLlmEndpoint = _llmEndpoint;
    AIExtractorService.enableGbnfConstraint = _enableGbnfConstraint;

    LocalModelManager.idleUnloadMinutes = _idleUnloadMinutes;
    LocalModelManager.enableThinkMode = _enableThinkMode;
    LocalModelManager.autoPreloadOnOverlayExpand = _autoPreloadOnOverlayExpand;
    LocalModelManager.contextSize = _contextSize;
    LocalModelManager.maxThinkingTokens = _maxThinkingTokens;
    LocalModelManager.temperature = _temperature;
    LocalModelManager.topP = _topP;
    LocalModelManager.repeatPenalty = _repeatPenalty;
  }

  /// 异步持久化配置到 JSON 文件
  Future<void> save() async {
    try {
      final file = await _resolveSettingsFile();
      final data = {
        'engineMode': _engineMode.name,
        'idleUnloadMinutes': _idleUnloadMinutes,
        'enableThinkMode': _enableThinkMode,
        'autoPreloadOnOverlayExpand': _autoPreloadOnOverlayExpand,
        'enableGbnfConstraint': _enableGbnfConstraint,
        'preferredModel': _preferredModel,
        'llmEndpoint': _llmEndpoint,
        'peerIp': _peerIp,
        'syncDeleteFromSystemCalendar': _syncDeleteFromSystemCalendar,
        'contextSize': _contextSize,
        'maxThinkingTokens': _maxThinkingTokens,
        'temperature': _temperature,
        'topP': _topP,
        'repeatPenalty': _repeatPenalty,
      };
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      _syncToServices();
    } catch (e) {
      debugPrint('[AppSettingsService] 保存配置异常: $e');
    }
  }

  // --- 状态更新与持久化方法 ---

  Future<void> setEngineMode(AIEngineMode mode) async {
    _engineMode = mode;
    AIExtractorService.currentEngineMode = mode;
    await save();
  }

  Future<void> setIdleUnloadMinutes(int minutes) async {
    _idleUnloadMinutes = minutes;
    LocalModelManager.idleUnloadMinutes = minutes;
    await save();
  }

  Future<void> setEnableThinkMode(bool val) async {
    _enableThinkMode = val;
    LocalModelManager.enableThinkMode = val;
    await save();
  }

  Future<void> setAutoPreloadOnOverlayExpand(bool val) async {
    _autoPreloadOnOverlayExpand = val;
    LocalModelManager.autoPreloadOnOverlayExpand = val;
    await save();
  }

  Future<void> setEnableGbnfConstraint(bool val) async {
    _enableGbnfConstraint = val;
    AIExtractorService.enableGbnfConstraint = val;
    await save();
  }

  Future<void> setPreferredModel(String? model) async {
    _preferredModel = model;
    AIExtractorService.currentPreferredModel = model;
    await save();
  }

  Future<void> setLlmEndpoint(String endpoint) async {
    _llmEndpoint = endpoint;
    AIExtractorService.currentLlmEndpoint = endpoint;
    await save();
  }

  Future<void> setPeerIp(String ip) async {
    _peerIp = ip;
    await save();
  }

  Future<void> setSyncDeleteFromSystemCalendar(bool val) async {
    _syncDeleteFromSystemCalendar = val;
    await save();
  }

  Future<void> setContextSize(int size) async {
    _contextSize = size.clamp(minContextSize, maxContextSize);
    LocalModelManager.contextSize = _contextSize;
    await save();
  }

  Future<void> setMaxThinkingTokens(int tokens) async {
    _maxThinkingTokens = tokens.clamp(minThinkingTokens, maxThinkingTokensLimit);
    LocalModelManager.maxThinkingTokens = _maxThinkingTokens;
    await save();
  }

  Future<void> setTemperature(double temp) async {
    _temperature = temp.clamp(minTemperature, maxTemperature);
    LocalModelManager.temperature = _temperature;
    await save();
  }

  Future<void> setTopP(double val) async {
    _topP = val.clamp(minTopP, maxTopP);
    LocalModelManager.topP = _topP;
    await save();
  }

  Future<void> setRepeatPenalty(double penalty) async {
    _repeatPenalty = penalty.clamp(minRepeatPenalty, maxRepeatPenalty);
    LocalModelManager.repeatPenalty = _repeatPenalty;
    await save();
  }

  Future<void> resetModelParamsToDefault() async {
    _contextSize = defaultContextSize;
    _maxThinkingTokens = defaultThinkingTokens;
    _temperature = defaultTemperature;
    _topP = defaultTopP;
    _repeatPenalty = defaultRepeatPenalty;
    _syncToServices();
    await save();
  }
}
