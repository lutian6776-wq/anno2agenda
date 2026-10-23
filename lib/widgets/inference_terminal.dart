import 'package:flutter/material.dart';

/// 实时端侧推理过程实况终端（带打字机流式输出、进度耗时、Token 统计与折叠面板）
class InferenceTerminal extends StatefulWidget {
  final bool isExtracting;
  final List<String> processLogs;
  final String streamedTokens;
  final int tokenCount;
  final double elapsedSeconds;

  const InferenceTerminal({
    super.key,
    required this.isExtracting,
    required this.processLogs,
    required this.streamedTokens,
    required this.tokenCount,
    required this.elapsedSeconds,
  });

  @override
  State<InferenceTerminal> createState() => _InferenceTerminalState();
}

class _InferenceTerminalState extends State<InferenceTerminal> {
  bool _showLogs = true;
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant InferenceTerminal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExtracting && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.processLogs.isEmpty &&
        widget.streamedTokens.isEmpty &&
        !widget.isExtracting) {
      return const SizedBox.shrink();
    }

    final isThinking = widget.isExtracting;
    final tokenSpeed = widget.elapsedSeconds > 0
        ? (widget.tokenCount / widget.elapsedSeconds).toStringAsFixed(1)
        : '0.0';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isThinking
              ? const Color(0xFF38BDF8)
              : const Color(0xFF334155),
          width: isThinking ? 1.5 : 1.0,
        ),
        boxShadow: isThinking
            ? [
                BoxShadow(
                  color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                )
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 终端标题栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF1E293B),
              borderRadius: BorderRadius.vertical(top: Radius.circular(13)),
            ),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                      color: Color(0xFFEF4444), shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                      color: Color(0xFFF59E0B), shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                      color: Color(0xFF10B981), shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                const Text(
                  '端侧推理实况',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE2E8F0),
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 8),
                if (isThinking) ...[
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF38BDF8),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '活跃 (${widget.tokenCount} tokens · $tokenSpeed t/s)',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF38BDF8),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ] else ...[
                  const Icon(Icons.check_circle,
                      size: 13, color: Color(0xFF34D399)),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '完成 (${widget.elapsedSeconds.toStringAsFixed(1)}s)',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF34D399),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                  tooltip: _showLogs ? '收起实况日志' : '展开实况日志',
                  icon: Icon(
                    _showLogs
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: Colors.grey.shade400,
                  ),
                  onPressed: () {
                    setState(() => _showLogs = !_showLogs);
                  },
                ),
              ],
            ),
          ),

          // 终端正文（可折叠）
          if (_showLogs)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final log in widget.processLogs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          log,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            color: log.contains('[完成]')
                                ? const Color(0xFF34D399)
                                : log.contains('[模式]') || log.contains('[思考]')
                                    ? const Color(0xFFFBBF24)
                                    : log.contains('[路由]') ||
                                            log.contains('[规则引擎]')
                                        ? const Color(0xFF60A5FA)
                                        : const Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                    if (widget.streamedTokens.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B)
                              .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF475569)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.stream,
                                    size: 12, color: Color(0xFF38BDF8)),
                                SizedBox(width: 4),
                                Text(
                                  '实时流式输出 (Tokens Stream):',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Color(0xFF38BDF8),
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.streamedTokens + (isThinking ? ' ▌' : ''),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: Color(0xFFF1F5F9),
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
