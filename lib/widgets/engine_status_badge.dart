import 'package:flutter/material.dart';
import '../services/ai_extractor_service.dart';
import '../services/local_model_manager.dart';

enum EngineIndicatorState {
  stopped, // 🔴 红色：未启动/未常驻内存/异常
  starting, // 🟡 黄色：正在启动/预热中
  ready, // 🟢 绿色：已就绪常驻内存
}

/// 顶部栏解析引擎状态指示徽章
class EngineStatusBadge extends StatelessWidget {
  final EngineIndicatorState state;
  final String detail;
  final AIEngineMode engineMode;
  final String? selectedModelName;
  final VoidCallback onPreloadModel;
  final VoidCallback onUnloadModel;
  final VoidCallback onNavigateToSettings;

  const EngineStatusBadge({
    super.key,
    required this.state,
    required this.detail,
    required this.engineMode,
    this.selectedModelName,
    required this.onPreloadModel,
    required this.onUnloadModel,
    required this.onNavigateToSettings,
  });

  void _showStatusDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        final (color, _) = switch (state) {
          EngineIndicatorState.stopped => (Colors.red.shade600, '未启动 / 未常驻内存'),
          EngineIndicatorState.starting => (Colors.amber.shade800, '正在启动中...'),
          EngineIndicatorState.ready => (Colors.green.shade600, '已就绪 (秒级响应)'),
        };

        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.psychology, color: color),
              const SizedBox(width: 8),
              const Text('解析引擎状态',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: color.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(
                      state == EngineIndicatorState.ready
                          ? Icons.check_circle
                          : state == EngineIndicatorState.starting
                              ? Icons.hourglass_top
                              : Icons.error_outline,
                      color: color,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        detail,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '• 当前推理路线: ${engineMode == AIEngineMode.hybridAuto ? "混合自动 (大模型优先+规则兜底)" : engineMode == AIEngineMode.builtInRuleEngine ? "纯端侧极速规则" : "强制大模型"}\n'
                '• 选定模型: ${selectedModelName ?? "未选定"}\n'
                '• 思考模式 (Think Mode): ${LocalModelManager.enableThinkMode ? "开启 (输出深度思考链)" : "关闭 (极速直出日程)"}\n'
                '• 空闲内存释放: ${LocalModelManager.idleUnloadMinutes > 0 ? "空闲 ${LocalModelManager.idleUnloadMinutes} 分钟后自动释放" : "永不释放 (保持常驻)"}',
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
            ],
          ),
          actions: [
            if (state == EngineIndicatorState.stopped)
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  onPreloadModel();
                },
                icon: const Icon(Icons.bolt, size: 16),
                label: const Text('立即启动预热'),
              ),
            if (state == EngineIndicatorState.ready)
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  onUnloadModel();
                },
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('释放内存 (卸载)'),
              ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                onNavigateToSettings();
              },
              child: const Text('前往设置'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (bgColor, borderColor, contentColor, iconWidget, labelText) =
        switch (state) {
      EngineIndicatorState.stopped => (
          isDark ? const Color(0xFF450A0A) : const Color(0xFFFEE2E2),
          isDark ? const Color(0xFF991B1B) : const Color(0xFFFCA5A5),
          isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
          Icon(Icons.error_outline,
              size: 15,
              color: isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626)),
          '未启动 (长按启动)',
        ),
      EngineIndicatorState.starting => (
          isDark ? const Color(0xFF451A03) : const Color(0xFFFEF3C7),
          isDark ? const Color(0xFFB45309) : const Color(0xFFFCD34D),
          isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
            ),
          ),
          '启动中...',
        ),
      EngineIndicatorState.ready => (
          isDark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7),
          isDark ? const Color(0xFF059669) : const Color(0xFF86EFAC),
          isDark ? const Color(0xFF34D399) : const Color(0xFF16A34A),
          Icon(Icons.check_circle_outline,
              size: 15,
              color: isDark ? const Color(0xFF34D399) : const Color(0xFF16A34A)),
          '就绪',
        ),
    };

    return Tooltip(
      message: '解析引擎状态：$labelText\n【长按】：直接启动/预热大模型\n【点击】：查看引擎状态与管理',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _showStatusDialog(context),
          onLongPress: onPreloadModel,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                iconWidget,
                const SizedBox(width: 5),
                Text(
                  '引擎: $labelText',
                  style: TextStyle(
                    fontSize: 12,
                    color: contentColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
