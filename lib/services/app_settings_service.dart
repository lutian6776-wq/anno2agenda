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

  // 云端大模型引擎配置项
  bool _enableCloudEngine = false;
  bool _cloudRiskAccepted = false;
  String _cloudApiUrl = '';
  String _cloudApiKey = '';
  String _cloudModelName = '';
  bool _enableCloudThinkMode = false;
  List<String> _favoriteCloudModels = [];
  List<String> _fetchedCloudModels = [];

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
  bool get enableCloudEngine => _enableCloudEngine;
  bool get cloudRiskAccepted => _cloudRiskAccepted;
  String get cloudApiUrl => _cloudApiUrl;
  String get cloudApiKey => _cloudApiKey;
  String get cloudModelName => _cloudModelName;
  bool get enableCloudThinkMode => _enableCloudThinkMode;
  List<String> get favoriteCloudModels =>
      List.unmodifiable(_favoriteCloudModels);
  List<String> get fetchedCloudModels => List.unmodifiable(_fetchedCloudModels);
  bool get isCloudConfigured =>
      _cloudApiUrl.trim().isNotEmpty && _cloudApiKey.trim().isNotEmpty;

  /// 判断收藏模型在最新拉取的模型列表中是否仍然可用（若尚未拉取列表则默认视为可用）
  bool isFavoriteCloudModelAvailable(String modelId) {
    if (_fetchedCloudModels.isEmpty) return true;
    return _fetchedCloudModels.contains(modelId);
  }

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

  void _resetToDefaults() {
    _engineMode = AIEngineMode.hybridAuto;
    _idleUnloadMinutes = 5;
    _enableThinkMode = false;
    _autoPreloadOnOverlayExpand = true;
    _enableGbnfConstraint = true;
    _preferredModel = null;
    _llmEndpoint = 'http://127.0.0.1:11434/api/generate';
    _peerIp = '';
    _syncDeleteFromSystemCalendar = true;
    _contextSize = defaultContextSize;
    _maxThinkingTokens = defaultThinkingTokens;
    _temperature = defaultTemperature;
    _topP = defaultTopP;
    _repeatPenalty = defaultRepeatPenalty;
    _enableCloudEngine = false;
    _cloudRiskAccepted = false;
    _cloudApiUrl = '';
    _cloudApiKey = '';
    _cloudModelName = '';
    _enableCloudThinkMode = false;
    _favoriteCloudModels = [];
    _fetchedCloudModels = [];
  }

  /// 初始化并从本地加载所有已保存的设置
  Future<void> init([String? storageDir]) async {
    try {
      _resetToDefaults();
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
            if (decoded.containsKey('enableCloudEngine')) {
              _enableCloudEngine =
                  decoded['enableCloudEngine'] as bool? ?? false;
            }
            if (decoded.containsKey('cloudRiskAccepted')) {
              _cloudRiskAccepted =
                  decoded['cloudRiskAccepted'] as bool? ?? false;
            }
            if (decoded.containsKey('cloudApiUrl')) {
              _cloudApiUrl = decoded['cloudApiUrl']?.toString() ?? '';
            }
            if (decoded.containsKey('cloudApiKey')) {
              _cloudApiKey = decoded['cloudApiKey']?.toString() ?? '';
            }
            if (decoded.containsKey('cloudModelName')) {
              _cloudModelName = decoded['cloudModelName']?.toString() ?? '';
            }
            if (decoded.containsKey('enableCloudThinkMode')) {
              _enableCloudThinkMode =
                  decoded['enableCloudThinkMode'] as bool? ?? false;
            }
            if (decoded['favoriteCloudModels'] is List) {
              _favoriteCloudModels = (decoded['favoriteCloudModels'] as List)
                  .map((e) => e.toString().trim())
                  .where((e) => e.isNotEmpty)
                  .toSet()
                  .toList();
            }
            if (decoded['fetchedCloudModels'] is List) {
              _fetchedCloudModels = (decoded['fetchedCloudModels'] as List)
                  .map((e) => e.toString().trim())
                  .where((e) => e.isNotEmpty)
                  .toSet()
                  .toList();
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
    AIExtractorService.enableCloudEngine = _enableCloudEngine;
    AIExtractorService.cloudApiUrl = _cloudApiUrl;
    AIExtractorService.cloudApiKey = _cloudApiKey;
    AIExtractorService.cloudModelName = _cloudModelName;
    AIExtractorService.enableCloudThinkMode = _enableCloudThinkMode;
    AIExtractorService.favoriteCloudModels = List.from(_favoriteCloudModels);
    AIExtractorService.fetchedCloudModels = List.from(_fetchedCloudModels);

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
    _syncToServices();
    if (skipPersistForTest) return;
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
        'enableCloudEngine': _enableCloudEngine,
        'cloudRiskAccepted': _cloudRiskAccepted,
        'cloudApiUrl': _cloudApiUrl,
        'cloudApiKey': _cloudApiKey,
        'cloudModelName': _cloudModelName,
        'enableCloudThinkMode': _enableCloudThinkMode,
        'favoriteCloudModels': _favoriteCloudModels,
        'fetchedCloudModels': _fetchedCloudModels,
      };
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
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

  // --- 云端引擎状态更新与持久化方法 ---

  Future<void> setEnableCloudEngine(bool val) async {
    _enableCloudEngine = val;
    AIExtractorService.enableCloudEngine = val;
    await save();
  }

  Future<void> setCloudRiskAccepted(bool val) async {
    _cloudRiskAccepted = val;
    await save();
  }

  Future<void> setCloudApiUrl(String url) async {
    _cloudApiUrl = url.trim();
    AIExtractorService.cloudApiUrl = _cloudApiUrl;
    AIExtractorService.resetCloudStatus();
    await save();
  }

  Future<void> setCloudApiKey(String key) async {
    _cloudApiKey = key.trim();
    AIExtractorService.cloudApiKey = _cloudApiKey;
    AIExtractorService.resetCloudStatus();
    await save();
  }

  Future<void> setCloudModelName(String model) async {
    _cloudModelName = model.trim();
    AIExtractorService.cloudModelName = _cloudModelName;
    await save();
  }

  Future<void> setCloudServiceConfig({
    required String apiUrl,
    required String apiKey,
    String? modelName,
  }) async {
    _cloudApiUrl = apiUrl.trim();
    _cloudApiKey = apiKey.trim();
    if (modelName != null) {
      _cloudModelName = modelName.trim();
    }
    AIExtractorService.cloudApiUrl = _cloudApiUrl;
    AIExtractorService.cloudApiKey = _cloudApiKey;
    AIExtractorService.cloudModelName = _cloudModelName;
    AIExtractorService.resetCloudStatus();
    await save();
  }

  Future<void> setEnableCloudThinkMode(bool val) async {
    _enableCloudThinkMode = val;
    AIExtractorService.enableCloudThinkMode = val;
    await save();
  }

  Future<void> setFavoriteCloudModels(List<String> models) async {
    final seen = <String>{};
    final deduped = <String>[];
    for (final m in models) {
      final trimmed = m.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed)) {
        deduped.add(trimmed);
      }
    }
    _favoriteCloudModels = deduped;
    await save();
  }

  Future<void> addFavoriteCloudModel(String modelId) async {
    final trimmed = modelId.trim();
    if (trimmed.isEmpty || _favoriteCloudModels.contains(trimmed)) return;
    _favoriteCloudModels = [..._favoriteCloudModels, trimmed];
    await save();
  }

  Future<void> removeFavoriteCloudModel(String modelId) async {
    final trimmed = modelId.trim();
    if (!_favoriteCloudModels.contains(trimmed)) return;
    _favoriteCloudModels =
        _favoriteCloudModels.where((m) => m != trimmed).toList();
    await save();
  }

  Future<void> toggleFavoriteCloudModel(String modelId) async {
    final trimmed = modelId.trim();
    if (trimmed.isEmpty) return;
    if (_favoriteCloudModels.contains(trimmed)) {
      await removeFavoriteCloudModel(trimmed);
    } else {
      await addFavoriteCloudModel(trimmed);
    }
  }

  Future<void> setFetchedCloudModels(List<String> models) async {
    final seen = <String>{};
    final deduped = <String>[];
    for (final m in models) {
      final trimmed = m.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed)) {
        deduped.add(trimmed);
      }
    }
    _fetchedCloudModels = deduped;
    if (deduped.isNotEmpty && _cloudModelName.trim().isEmpty) {
      final availableFav = _favoriteCloudModels.firstWhere(
        (f) => deduped.contains(f),
        orElse: () => '',
      );
      _cloudModelName =
          availableFav.isNotEmpty ? availableFav : deduped.first;
    }
    await save();
  }

  @visibleForTesting
  bool skipPersistForTest = false;

  @visibleForTesting
  void resetForTest() {
    _resetToDefaults();
    _settingsFile = null;
    _isInitialized = false;
    skipPersistForTest = false;
    _syncToServices();
    AIExtractorService.resetCloudStatus();
  }
}
