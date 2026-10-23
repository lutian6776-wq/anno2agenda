import 'dart:io';
import 'package:flutter/material.dart';
import '../models/agenda_event.dart';
import 'agenda_event_card.dart';

/// 收到系统划词、分享或悬浮窗直达时的快速确认底部弹窗
class QuickCaptureBottomSheet extends StatelessWidget {
  final String sourceType;
  final List<AgendaEvent> draftEvents;
  final Future<void> Function() onConfirmAll;

  const QuickCaptureBottomSheet({
    super.key,
    required this.sourceType,
    required this.draftEvents,
    required this.onConfirmAll,
  });

  static Future<void> show(
    BuildContext context, {
    required String sourceType,
    required List<AgendaEvent> draftEvents,
    required Future<void> Function() onConfirmAll,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => QuickCaptureBottomSheet(
        sourceType: sourceType,
        draftEvents: draftEvents,
        onConfirmAll: onConfirmAll,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sourceLabel = switch (sourceType) {
      'process_text' => '系统划词直达 (ACTION_PROCESS_TEXT)',
      'share' => '系统分享面板 (ACTION_SEND)',
      'floating' => '全局悬浮窗截获',
      _ => '快捷捕获',
    };

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF1E3A8A)
                          : Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.bolt,
                          size: 16,
                          color: isDark
                              ? const Color(0xFF60A5FA)
                              : Colors.blue,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            sourceLabel,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? const Color(0xFF93C5FD)
                                  : Colors.blue,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '已从通知中识别出 ${draftEvents.length} 个日程事项',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: draftEvents.length,
                itemBuilder: (_, idx) {
                  final ev = draftEvents[idx];
                  return Card(
                    elevation: 0,
                    color: isDark
                        ? const Color(0xFF0F172A)
                        : const Color(0xFFF8FAFC),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isDark
                            ? const Color(0xFF334155)
                            : const Color(0xFFE2E8F0),
                      ),
                    ),
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isDark
                            ? const Color(0xFF1E3A8A)
                            : Colors.blue.shade50,
                        child: Icon(
                          Icons.event_available,
                          color: isDark
                              ? const Color(0xFF60A5FA)
                              : const Color(0xFF2563EB),
                        ),
                      ),
                      title: Text(
                        ev.title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                      subtitle: Text(
                        '🕒 ${AgendaEventCard.formatDateTime(ev.startTime)}\n📍 ${ev.location.isEmpty ? "待定" : ev.location}',
                        style: TextStyle(
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(context);
                  await onConfirmAll();
                },
                icon: const Icon(Icons.calendar_month),
                label: Text(
                  Platform.isAndroid
                      ? '一键静默写入 Android 系统日历 (${draftEvents.length}项)'
                      : '全部导入系统日历',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
