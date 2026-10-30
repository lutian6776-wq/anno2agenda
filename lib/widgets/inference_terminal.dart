import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/inference_terminal_model.dart';
import '../theme/app_theme.dart';

/// 现代 AI 应用风格的端侧推理监控模组
///
/// 具备「三列推理仪表盘 + 可折叠思考流卡片」设计：
/// 1. 顶部三列状态栏（状态、等宽推理速度、Token 计数）
/// 2. 模型思考时自动展开滚动思考流
/// 3. 解析完成后自动平滑收起并提供紧凑复盘折叠条
class InferenceTerminal extends StatefulWidget {
  /// 绑定的推理实况模型（推荐方式）
  final InferenceTerminalModel? model;

  /// 显式传入的状态（向下兼容）
  final bool? isExtracting;
  final List<String>? processLogs;
  final String? streamedTokens;
  final int? tokenCount;
  final double? elapsedSeconds;

  /// 最大高度限制
  final double? maxHeight;

  /// 初始是否展开
  final bool initialExpanded;

  /// 标题（向下兼容保留）
  final String title;

  const InferenceTerminal({
    super.key,
    this.model,
    this.isExtracting,
    this.processLogs,
    this.streamedTokens,
    this.tokenCount,
    this.elapsedSeconds,
    this.maxHeight,
    this.initialExpanded = false,
    this.title = '端侧推理实况',
  });

  @override
  State<InferenceTerminal> createState() => _InferenceTerminalState();
}

class _InferenceTerminalState extends State<InferenceTerminal>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  bool _manualExpanded = false;
  bool _lastExtracting = false;

  bool get _effectiveExtracting =>
      widget.model?.isExtracting ?? widget.isExtracting ?? false;

  List<String> get _effectiveProcessLogs =>
      widget.model?.processLogs ?? widget.processLogs ?? const [];

  String get _effectiveStreamedTokens =>
      widget.model?.streamedTokens ?? widget.streamedTokens ?? '';

  int get _effectiveTokenCount =>
      widget.model?.tokenCount ?? widget.tokenCount ?? 0;

  double get _effectiveElapsedSeconds =>
      widget.model?.elapsedSeconds ?? widget.elapsedSeconds ?? 0.0;

  String get _displayContent {
    final tokens = _effectiveStreamedTokens;
    final logs = _effectiveProcessLogs;
    if (tokens.isNotEmpty && logs.isNotEmpty) {
      return '${logs.join('\n')}\n\n$tokens';
    } else if (tokens.isNotEmpty) {
      return tokens;
    } else {
      return logs.join('\n');
    }
  }

  @override
  void initState() {
    super.initState();
    _manualExpanded = widget.initialExpanded;
    _lastExtracting = _effectiveExtracting;
    widget.model?.addListener(_onModelUpdated);
  }

  void _checkExtractingTransition() {
    final currentExtracting = _effectiveExtracting;
    if (_lastExtracting && !currentExtracting) {
      // 模型完成思考与结构化解析后，思考框平滑收起高度为 0
      _manualExpanded = false;
    }
    _lastExtracting = currentExtracting;
  }

  void _onModelUpdated() {
    if (mounted) {
      _checkExtractingTransition();
      setState(() {});
      _autoScrollIfNeeded();
    }
  }

  @override
  void didUpdateWidget(covariant InferenceTerminal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model?.removeListener(_onModelUpdated);
      widget.model?.addListener(_onModelUpdated);
    }
    _checkExtractingTransition();
    _autoScrollIfNeeded();
  }

  void _autoScrollIfNeeded() {
    if (_effectiveExtracting && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    widget.model?.removeListener(_onModelUpdated);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logs = _effectiveProcessLogs;
    final tokens = _effectiveStreamedTokens;
    final isThinking = _effectiveExtracting;
    final tokenCount = _effectiveTokenCount;
    final elapsedSec = _effectiveElapsedSeconds;
    final content = _displayContent;

    // 当空闲且无任何日志/Token 时不占用空间
    if (logs.isEmpty && tokens.isEmpty && !isThinking) {
      return const SizedBox.shrink();
    }

    final appColors = context.appColors;
    final leafGreen = appColors.tagWork; // 统一应用叶绿色 (#35B890)
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final tokenSpeed = elapsedSec > 0
        ? (tokenCount / elapsedSec).toStringAsFixed(1)
        : '0.0';

    // 思考流卡片可见性：推理中只要有内容即展开；完成之后取决于用户手动展开
    final isThinkingBoxOpen =
        (isThinking && content.isNotEmpty) || (!isThinking && _manualExpanded);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: appColors.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isThinking
              ? leafGreen.withValues(alpha: 0.4)
              : appColors.borderSubtle.withValues(alpha: 0.8),
          width: 1,
        ),
        boxShadow: isThinking
            ? [
                BoxShadow(
                  color: leafGreen.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. 顶部三列仪表盘状态栏（第一列：spinner一行/运行中一行；其余列：数字一行/单位一行）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                // 第一列（状态：微型叶绿 Spinner/小圆点一行，运行中/状态说明一行）
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 24,
                        child: Center(
                          child: isThinking
                              ? SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: leafGreen,
                                  ),
                                )
                              : Container(
                                  width: 15,
                                  height: 15,
                                  decoration: BoxDecoration(
                                    color: leafGreen,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isThinking
                            ? '运行中'
                            : (tokenCount > 0 ? '已完成' : '已就绪'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isThinking
                              ? leafGreen
                              : appColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),

                // 细分隔线
                Container(
                  width: 1,
                  height: 30,
                  color: appColors.borderSubtle.withValues(alpha: 0.6),
                ),

                // 第二列（推理速度：数字一行，单位 t/s 一行）
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 24,
                        child: Center(
                          child: Text(
                            tokenSpeed,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                              color: appColors.textPrimary,
                              height: 1.1,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        't/s',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: appColors.textTertiary,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),

                // 细分隔线
                Container(
                  width: 1,
                  height: 30,
                  color: appColors.borderSubtle.withValues(alpha: 0.6),
                ),

                // 第三列（Token 计数：数字一行，单位 tokens 一行）
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 24,
                        child: Center(
                          child: Text(
                            '$tokenCount',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                              color: appColors.textPrimary,
                              height: 1.1,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'tokens',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: appColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if ((!isThinking && content.isNotEmpty) || isThinkingBoxOpen)
            Divider(
              height: 1,
              thickness: 1,
              color: appColors.borderSubtle.withValues(alpha: 0.4),
            ),

          // 2. 完成后显示的紧凑折叠条：“✨ 已完成思考和解析 (展开/收起 ▾)”
          if (!isThinking && content.isNotEmpty)
            InkWell(
              onTap: () {
                setState(() {
                  _manualExpanded = !_manualExpanded;
                });
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    Text(
                      '✨ 已完成思考和解析',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: leafGreen,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _manualExpanded ? '(收起 ▴)' : '(展开/收起 ▾)',
                      style: TextStyle(
                        fontSize: 11,
                        color: appColors.textTertiary,
                      ),
                    ),
                    const Spacer(),
                    Tooltip(
                      message: '复制思考与输出内容',
                      child: InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: content));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已复制思考与输出内容'),
                              behavior: SnackBarBehavior.floating,
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.copy_rounded,
                            size: 13,
                            color: appColors.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 3. 平滑展开式思考流（Thinking Box）
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: isThinkingBoxOpen
                ? Container(
                    constraints: BoxConstraints(
                      maxHeight: widget.maxHeight ?? 190,
                    ),
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.black.withValues(alpha: 0.28)
                          : appColors.surfaceLow.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: appColors.borderSubtle.withValues(alpha: 0.5),
                        width: 1,
                      ),
                    ),
                    child: Scrollbar(
                      controller: _scrollController,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: SelectableText(
                          content + (isThinking ? ' ▌' : ''),
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: appColors.textSecondary,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
