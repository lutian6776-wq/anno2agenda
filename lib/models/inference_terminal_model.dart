import 'dart:async';
import 'package:flutter/foundation.dart';

/// 提取/推理进度回调函数签名（与 AIExtractorService 完全对齐）
typedef ExtractionProgressCallback = void Function({
  String? stepLog,
  String? token,
  int? tokenCount,
});

/// 模型推理实况数据与逻辑模型 (InferenceTerminalModel)
///
/// 封装端侧/云端大模型在流式生成过程中的日志记录、Token 打字机流、耗时秒表、
/// 生成速度计算、定时器调度与错误收集，可被主工作台「AI提取」、原生悬浮窗后台
/// 以及「系统提示词修改与测试」等多个界面和终端模组无缝复用。
class InferenceTerminalModel extends ChangeNotifier {
  bool _isExtracting = false;
  final List<String> _processLogs = [];
  final StringBuffer _tokenBuffer = StringBuffer();
  int _tokenCount = 0;
  double _elapsedSeconds = 0.0;
  Stopwatch? _stopwatch;
  Timer? _ticker;

  /// 是否正在进行端侧/远端模型推理提取
  bool get isExtracting => _isExtracting;

  /// 结构化过程步骤与诊断日志列表（不可修改视图）
  List<String> get processLogs => List.unmodifiable(_processLogs);

  /// 实时流式输出的完整 Token 拼接文本
  String get streamedTokens => _tokenBuffer.toString();

  /// 当前已输出的 Token 总数
  int get tokenCount => _tokenCount;

  /// 当前推理已消耗的秒数
  double get elapsedSeconds => _elapsedSeconds;

  /// 当前实况面板是否已有日志、Token 或处于活跃状态
  bool get hasContent =>
      _processLogs.isNotEmpty || _tokenBuffer.isNotEmpty || _isExtracting;

  /// 当前推理速度 (Tokens Per Second)
  double get tokenSpeed =>
      _elapsedSeconds > 0 ? (_tokenCount / _elapsedSeconds) : 0.0;

  /// 格式化后的 Token 生成速率字符串（如 "18.5"）
  String get tokenSpeedFormatted => tokenSpeed.toStringAsFixed(1);

  /// 格式化后的耗时秒数字符串（如 "2.4"）
  String get elapsedSecondsFormatted => _elapsedSeconds.toStringAsFixed(1);

  /// 终端全部内容（供一键复制使用：若有流式 Token 则返回 Token，否则返回日志全文）
  String get fullContent =>
      streamedTokens.isNotEmpty ? streamedTokens : _processLogs.join('\n');

  /// 格式化当前时间戳 [HH:mm:ss.S]
  static String formatTimestamp(DateTime now) {
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    final ms = (now.millisecond ~/ 100).toString();
    return '$h:$m:$s.$ms';
  }

  /// 启动一次新的推理会话：重置状态、重置秒表并开启高频 (100ms) 耗时计时器
  void start({String? initialLog}) {
    _ticker?.cancel();
    _stopwatch?.stop();

    _isExtracting = true;
    _processLogs.clear();
    _tokenBuffer.clear();
    _tokenCount = 0;
    _elapsedSeconds = 0.0;

    _stopwatch = Stopwatch()..start();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_isExtracting) {
        _elapsedSeconds =
            (_stopwatch?.elapsedMilliseconds ?? 0) / 1000.0;
        notifyListeners();
      }
    });

    if (initialLog != null && initialLog.isNotEmpty) {
      addLog(initialLog);
    } else {
      notifyListeners();
    }
  }

  /// 追加一条带有格式化时间戳的步骤日志
  void addLog(String stepLog, {bool withTimestamp = true}) {
    if (stepLog.isEmpty) return;
    if (withTimestamp) {
      final timeStr = formatTimestamp(DateTime.now());
      _processLogs.add('[$timeStr] $stepLog');
    } else {
      _processLogs.add(stepLog);
    }
    notifyListeners();
  }

  /// 收到单个增量 Token 并追加至流式缓冲区
  void appendToken(String token, {int? tokenCount}) {
    _tokenBuffer.write(token);
    if (tokenCount != null) {
      _tokenCount = tokenCount;
    }
    notifyListeners();
  }

  /// 处理推理服务吐出的增量进度（自动分发日志、Token 与计数值）
  void handleProgress({
    String? stepLog,
    String? token,
    int? tokenCount,
  }) {
    var changed = false;
    if (stepLog != null && stepLog.isNotEmpty) {
      final timeStr = formatTimestamp(DateTime.now());
      _processLogs.add('[$timeStr] $stepLog');
      changed = true;
    }
    if (token != null) {
      _tokenBuffer.write(token);
      changed = true;
    }
    if (tokenCount != null) {
      _tokenCount = tokenCount;
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }

  /// 快速适配 AIExtractorService 的标准 progress 回调
  ExtractionProgressCallback get progressCallback =>
      ({stepLog, token, tokenCount}) => handleProgress(
            stepLog: stepLog,
            token: token,
            tokenCount: tokenCount,
          );

  /// 结束推理会话并停止计时
  void finish({String? completionLog}) {
    _ticker?.cancel();
    _ticker = null;
    _stopwatch?.stop();
    _elapsedSeconds =
        (_stopwatch?.elapsedMilliseconds ?? 0) / 1000.0;
    _isExtracting = false;

    if (completionLog != null && completionLog.isNotEmpty) {
      addLog(completionLog);
    } else {
      notifyListeners();
    }
  }

  /// 记录推理或网络异常，安全停止计时器
  void recordError(dynamic error, {String prefix = '[错误]'}) {
    _ticker?.cancel();
    _ticker = null;
    _stopwatch?.stop();
    _elapsedSeconds =
        (_stopwatch?.elapsedMilliseconds ?? 0) / 1000.0;
    _isExtracting = false;

    addLog('$prefix $error');
  }

  /// 清空终端实况的所有内容
  void clear() {
    _ticker?.cancel();
    _ticker = null;
    _stopwatch?.stop();
    _isExtracting = false;
    _processLogs.clear();
    _tokenBuffer.clear();
    _tokenCount = 0;
    _elapsedSeconds = 0.0;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    _stopwatch?.stop();
    super.dispose();
  }
}
