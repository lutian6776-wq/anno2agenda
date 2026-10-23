import 'package:flutter/material.dart';

/// 顶部栏悬浮窗权限状态徽章（红：未启动/未授权，绿：就绪运行中）
class FloatingStatusBadge extends StatelessWidget {
  final bool isRunning;
  final VoidCallback onToggle;

  const FloatingStatusBadge({
    super.key,
    required this.isRunning,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isRunning
        ? (isDark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7))
        : (isDark ? const Color(0xFF450A0A) : const Color(0xFFFEE2E2));
    final borderColor = isRunning
        ? (isDark ? const Color(0xFF059669) : const Color(0xFF86EFAC))
        : (isDark ? const Color(0xFF991B1B) : const Color(0xFFFCA5A5));
    final contentColor = isRunning
        ? (isDark ? const Color(0xFF34D399) : const Color(0xFF16A34A))
        : (isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626));
    final iconData =
        isRunning ? Icons.layers_outlined : Icons.layers_clear_outlined;
    final textLabel = isRunning ? '悬浮窗就绪' : '悬浮窗未开启';

    return Tooltip(
      message: isRunning ? '悬浮窗正在运行中，点击可关闭' : '悬浮窗未开启，点击快速授权并开启',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onToggle,
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
                Icon(iconData, size: 15, color: contentColor),
                const SizedBox(width: 5),
                Text(
                  textLabel,
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
